package httpapi_test

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/jpeg"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"strings"
	"testing"
	"time"
)

// Receipt permission matrix.
//
//	            submit  list-own  list-review  view-own  view-other  withdraw-own  approve
//	instructor    ✓        ✓          ✗           ✓          ✗            ✓           ✗
//	admin         ✗        ✓          ✓           ✓ (all)              ✗           ✓
//	owner         ✗        ✓          ✓           ✓ (all)              ✗           ✓
//	student       ✗        ✓ (empty) ✗           ✗          ✗            ✗           ✗
//
// One end-to-end test per row plus a few cross-checks. Uses the
// ledger fixture (admin + student + instructor + seeded category).

type receiptFixture struct {
	*ledgerFixture
	instructorToken string
	categoryID      string
}

func newReceiptFixture(t *testing.T) *receiptFixture {
	t.Helper()
	f := newLedgerFixture(t)
	// Seed an active expense category for the school.
	if _, err := f.db.Exec(`INSERT INTO expense_categories (id, school_id, label, icon, tone, sort_order, active, created_at)
	                       VALUES ('cat_petrol','school_t','Petrol','fuel',277,1,1,?)`,
		time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	rf := &receiptFixture{
		ledgerFixture:   f,
		instructorToken: f.loginAs("instr@test"),
		categoryID:      "cat_petrol",
	}
	return rf
}

// makeJPEG builds a small in-memory JPEG so tests don't need binary
// fixtures. Size is deliberately modest — the compression pipeline
// won't bother resizing.
func makeJPEG(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 200, 150))
	for y := 0; y < 150; y++ {
		for x := 0; x < 200; x++ {
			img.Set(x, y, color.RGBA{R: 200, G: 100, B: 50, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// uploadReceipt POSTs /me/expenses with the given auth token and
// returns the response status, body, and any decoded expense ID for
// follow-up assertions.
func (rf *receiptFixture) uploadReceipt(t *testing.T, token string) (*http.Response, []byte) {
	t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	_ = mw.WriteField("categoryId", rf.categoryID)
	_ = mw.WriteField("amountPence", "3200")
	_ = mw.WriteField("occurredAt", time.Now().UTC().Format(time.RFC3339))
	_ = mw.WriteField("where", "Local petrol station")

	h := make(textproto.MIMEHeader)
	h.Set("Content-Disposition", `form-data; name="receipt"; filename="receipt.jpg"`)
	h.Set("Content-Type", "image/jpeg")
	part, err := mw.CreatePart(h)
	if err != nil {
		t.Fatal(err)
	}
	part.Write(makeJPEG(t))
	mw.Close()

	req, _ := http.NewRequest("POST", rf.srv.URL+"/me/expenses", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	buf := new(bytes.Buffer)
	buf.ReadFrom(resp.Body)
	return resp, buf.Bytes()
}

// ----- Submit -----

func TestReceipts_InstructorCanSubmit(t *testing.T) {
	rf := newReceiptFixture(t)
	resp, body := rf.uploadReceipt(t, rf.instructorToken)
	if resp.StatusCode != 201 {
		t.Fatalf("submit: %d body=%s", resp.StatusCode, body)
	}
	var out struct {
		Expense struct {
			ID, Status, InstructorID, ReceiptThumb string
			ReceiptSizeBytes                       int
		}
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatal(err)
	}
	if out.Expense.Status != "pending" {
		t.Errorf("expected status pending, got %s", out.Expense.Status)
	}
	if out.Expense.InstructorID != "user_instr" {
		t.Errorf("instructorId got %q want user_instr", out.Expense.InstructorID)
	}
	if out.Expense.ReceiptSizeBytes <= 0 {
		t.Errorf("expected receiptSizeBytes > 0, got %d", out.Expense.ReceiptSizeBytes)
	}
	// Server-side compression always emits JPEG. The thumb should be a
	// non-trivial base64 string.
	if len(out.Expense.ReceiptThumb) < 100 {
		t.Errorf("thumb too small: %d chars", len(out.Expense.ReceiptThumb))
	}
	thumb, err := base64.StdEncoding.DecodeString(out.Expense.ReceiptThumb)
	if err != nil {
		t.Errorf("thumb base64 decode: %v", err)
	}
	// JPEG magic bytes.
	if len(thumb) < 3 || thumb[0] != 0xFF || thumb[1] != 0xD8 || thumb[2] != 0xFF {
		t.Errorf("thumb not a JPEG (magic bytes: % x)", thumb[:3])
	}
}

func TestReceipts_AdminCannotSubmit(t *testing.T) {
	rf := newReceiptFixture(t)
	resp, body := rf.uploadReceipt(t, rf.adminToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for admin submit, got %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "instructors only") {
		t.Errorf("expected 'instructors only' message, got %s", body)
	}
}

func TestReceipts_StudentCannotSubmit(t *testing.T) {
	rf := newReceiptFixture(t)
	resp, _ := rf.uploadReceipt(t, rf.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for student submit, got %d", resp.StatusCode)
	}
}

// ----- List for review -----

func TestReceipts_AdminCanListAllForReview(t *testing.T) {
	rf := newReceiptFixture(t)
	rf.uploadReceipt(t, rf.instructorToken)
	resp, body := rf.do("GET", "/expenses?status=pending", nil, rf.adminToken)
	if resp.StatusCode != 200 {
		t.Fatalf("list: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"status":"pending"`) {
		t.Errorf("expected at least one pending expense in admin list, got %s", body)
	}
	if !strings.Contains(string(body), `"receiptThumb":"`) {
		t.Errorf("expected inline base64 thumb in list payload, got %s", body)
	}
}

func TestReceipts_InstructorCannotListForReview(t *testing.T) {
	rf := newReceiptFixture(t)
	resp, body := rf.do("GET", "/expenses", nil, rf.instructorToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for instructor on review list, got %d body=%s", resp.StatusCode, body)
	}
}

func TestReceipts_StudentCannotListForReview(t *testing.T) {
	rf := newReceiptFixture(t)
	resp, _ := rf.do("GET", "/expenses", nil, rf.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for student on review list, got %d", resp.StatusCode)
	}
}

// ----- View own + cross-instructor isolation -----

func TestReceipts_InstructorReadsOwnReceipt(t *testing.T) {
	rf := newReceiptFixture(t)
	_, body := rf.uploadReceipt(t, rf.instructorToken)
	var sub struct {
		Expense struct{ ID string }
	}
	json.Unmarshal(body, &sub)

	resp, raw := rf.do("GET", "/expenses/"+sub.Expense.ID+"/receipt", nil, rf.instructorToken)
	if resp.StatusCode != 200 {
		t.Fatalf("read receipt: %d body=%s", resp.StatusCode, raw)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "image/jpeg" {
		t.Errorf("expected image/jpeg, got %s", ct)
	}
	// JPEG magic bytes on the streamed body.
	if len(raw) < 3 || raw[0] != 0xFF || raw[1] != 0xD8 || raw[2] != 0xFF {
		t.Errorf("body not a JPEG (magic: % x)", raw[:3])
	}
}

func TestReceipts_AdminReadsAnyInstructorsReceipt(t *testing.T) {
	rf := newReceiptFixture(t)
	_, body := rf.uploadReceipt(t, rf.instructorToken)
	var sub struct {
		Expense struct{ ID string }
	}
	json.Unmarshal(body, &sub)

	resp, _ := rf.do("GET", "/expenses/"+sub.Expense.ID+"/receipt", nil, rf.adminToken)
	if resp.StatusCode != 200 {
		t.Errorf("admin should read any receipt, got %d", resp.StatusCode)
	}
}

func TestReceipts_StudentCannotReadAnyReceipt(t *testing.T) {
	rf := newReceiptFixture(t)
	_, body := rf.uploadReceipt(t, rf.instructorToken)
	var sub struct {
		Expense struct{ ID string }
	}
	json.Unmarshal(body, &sub)

	resp, _ := rf.do("GET", "/expenses/"+sub.Expense.ID+"/receipt", nil, rf.studentToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for student receipt access, got %d", resp.StatusCode)
	}
}

func TestReceipts_OtherInstructorCannotRead(t *testing.T) {
	rf := newReceiptFixture(t)
	// Add a second instructor in the same school, mint a token for them,
	// then submit a receipt as the seeded instructor.
	if _, err := rf.db.Exec(`INSERT INTO users (id, school_id, email, password_hash, name, role, account_status, created_at)
	                        VALUES ('user_instr2','school_t','instr2@test','','Other Instr','instructor','active',?)`,
		time.Now().UTC().Format(time.RFC3339)); err != nil {
		t.Fatal(err)
	}
	if _, err := rf.db.Exec(`INSERT INTO instructor_profiles (user_id, school_id, home_location_id)
	                        VALUES ('user_instr2','school_t','loc_t')`); err != nil {
		t.Fatal(err)
	}
	otherTok := rf.mintToken("user_instr2")

	_, body := rf.uploadReceipt(t, rf.instructorToken)
	var sub struct {
		Expense struct{ ID string }
	}
	json.Unmarshal(body, &sub)

	resp, raw := rf.do("GET", "/expenses/"+sub.Expense.ID+"/receipt", nil, otherTok)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for other instructor receipt access, got %d body=%s",
			resp.StatusCode, raw)
	}
}

// ----- Withdraw + approve workflow -----

func TestReceipts_InstructorCanWithdrawOwn(t *testing.T) {
	rf := newReceiptFixture(t)
	_, body := rf.uploadReceipt(t, rf.instructorToken)
	var sub struct {
		Expense struct{ ID string }
	}
	json.Unmarshal(body, &sub)

	resp, raw := rf.do("DELETE", "/me/expenses/"+sub.Expense.ID, nil, rf.instructorToken)
	if resp.StatusCode != 200 {
		t.Errorf("withdraw: %d body=%s", resp.StatusCode, raw)
	}
}

func TestReceipts_AdminCannotWithdraw(t *testing.T) {
	rf := newReceiptFixture(t)
	_, body := rf.uploadReceipt(t, rf.instructorToken)
	var sub struct {
		Expense struct{ ID string }
	}
	json.Unmarshal(body, &sub)

	// Admin shouldn't be able to use /me/expenses/{id} at all — that's
	// the instructor's withdraw path.
	resp, _ := rf.do("DELETE", "/me/expenses/"+sub.Expense.ID, nil, rf.adminToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for admin withdraw, got %d", resp.StatusCode)
	}
}

func TestReceipts_AdminCanApprove(t *testing.T) {
	rf := newReceiptFixture(t)
	_, body := rf.uploadReceipt(t, rf.instructorToken)
	var sub struct {
		Expense struct{ ID string }
	}
	json.Unmarshal(body, &sub)

	resp, raw := rf.do("POST", "/expenses/"+sub.Expense.ID+"/approve",
		map[string]string{"reviewerNote": "looks good"}, rf.adminToken)
	if resp.StatusCode != 200 {
		t.Errorf("approve: %d body=%s", resp.StatusCode, raw)
	}
}

func TestReceipts_InstructorCannotApprove(t *testing.T) {
	rf := newReceiptFixture(t)
	_, body := rf.uploadReceipt(t, rf.instructorToken)
	var sub struct {
		Expense struct{ ID string }
	}
	json.Unmarshal(body, &sub)

	resp, _ := rf.do("POST", "/expenses/"+sub.Expense.ID+"/approve",
		map[string]string{"reviewerNote": "self-approve"}, rf.instructorToken)
	if resp.StatusCode != 403 {
		t.Errorf("expected 403 for instructor self-approve, got %d", resp.StatusCode)
	}
}
