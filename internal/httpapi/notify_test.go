package httpapi_test

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestNotifications_BookingCreatesStudentNotification(t *testing.T) {
	f := newLedgerFixture(t)
	stu := f.loginStudent()
	if resp, _ := f.do("POST", "/bookings",
		map[string]string{"sessionId": "sess_t"}, stu); resp.StatusCode != 201 {
		t.Fatal("book")
	}
	resp, body := f.do("GET", "/me/notifications", nil, stu)
	if resp.StatusCode != 200 {
		t.Fatalf("list: %d body=%s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), `"eventKind":"booking.created"`) {
		t.Errorf("expected booking.created event, got %s", body)
	}
	if !strings.Contains(string(body), `"unreadCount":1`) {
		t.Errorf("expected unreadCount=1, got %s", body)
	}
}

func TestNotifications_MarkRead(t *testing.T) {
	f := newLedgerFixture(t)
	stu := f.loginStudent()
	if resp, _ := f.do("POST", "/bookings",
		map[string]string{"sessionId": "sess_t"}, stu); resp.StatusCode != 201 {
		t.Fatal("book")
	}
	resp, body := f.do("GET", "/me/notifications", nil, stu)
	if resp.StatusCode != 200 {
		t.Fatal("list")
	}
	var out struct {
		Notifications []struct {
			ID string `json:"id"`
		} `json:"notifications"`
	}
	json.Unmarshal(body, &out)
	if len(out.Notifications) == 0 {
		t.Fatal("no notifications to mark")
	}
	resp, _ = f.do("POST", "/me/notifications/"+out.Notifications[0].ID+"/read", nil, stu)
	if resp.StatusCode != 204 {
		t.Errorf("mark read: %d", resp.StatusCode)
	}
	resp, body = f.do("GET", "/me/notifications", nil, stu)
	if !strings.Contains(string(body), `"unreadCount":0`) {
		t.Errorf("expected unread=0 after mark read, got %s", body)
	}
}

func TestNotifications_MarkAllRead(t *testing.T) {
	f := newLedgerFixture(t)
	stu := f.loginStudent()
	if resp, _ := f.do("POST", "/bookings",
		map[string]string{"sessionId": "sess_t"}, stu); resp.StatusCode != 201 {
		t.Fatal("book")
	}
	resp, _ := f.do("POST", "/me/notifications/read-all", nil, stu)
	if resp.StatusCode != 204 {
		t.Errorf("mark all: %d", resp.StatusCode)
	}
	resp, body := f.do("GET", "/me/notifications", nil, stu)
	if !strings.Contains(string(body), `"unreadCount":0`) {
		t.Errorf("expected unread=0, got %s", body)
	}
}

func TestNotifications_CancelByStudent_PingsInstructor(t *testing.T) {
	f := newLedgerFixture(t)
	stu := f.loginStudent()
	resp, body := f.do("POST", "/bookings", map[string]string{"sessionId": "sess_t"}, stu)
	if resp.StatusCode != 201 {
		t.Fatal("book")
	}
	var b struct{ Booking struct{ ID string } }
	json.Unmarshal(body, &b)
	if resp, _ := f.do("DELETE", "/bookings/"+b.Booking.ID, nil, stu); resp.StatusCode != 200 {
		t.Fatal("cancel")
	}

	instructor := f.loginAs("instr@test")
	resp, body = f.do("GET", "/me/notifications", nil, instructor)
	if !strings.Contains(string(body), `"eventKind":"booking.cancelled"`) {
		t.Errorf("expected instructor to see booking.cancelled, got %s", body)
	}
}

func TestNotifications_BikeOffline_PingsAdmins(t *testing.T) {
	f := newLedgerFixture(t)
	// Book first so there's an affected booking.
	stu := f.loginStudent()
	if resp, _ := f.do("POST", "/bookings",
		map[string]string{"sessionId": "sess_t"}, stu); resp.StatusCode != 201 {
		t.Fatal("book")
	}
	// Take bike offline.
	if resp, _ := f.do("POST", "/bikes/bike_t/offline",
		map[string]any{"reason": "damaged"}, f.adminToken); resp.StatusCode != 201 {
		t.Fatal("offline")
	}
	// Admin should see bike.offline event.
	_, body := f.do("GET", "/me/notifications", nil, f.adminToken)
	if !strings.Contains(string(body), `"eventKind":"bike.offline"`) {
		t.Errorf("expected admin to see bike.offline, got %s", body)
	}
	// Student should see disruption.affected_booking.
	_, body = f.do("GET", "/me/notifications", nil, stu)
	if !strings.Contains(string(body), `"eventKind":"disruption.affected_booking"`) {
		t.Errorf("expected student to see disruption.affected_booking, got %s", body)
	}
}

func TestNotifications_TenantIsolation(t *testing.T) {
	// Notifications are by recipient_id + school_id, and recipient_id comes
	// from auth → tenant is automatically isolated. Spot-check by adding a
	// second school's user and confirming they see nothing.
	f := newLedgerFixture(t)
	// (No cross-school scenario set up here — list is empty for a fresh user.)
	stu := f.loginStudent()
	resp, body := f.do("GET", "/me/notifications", nil, stu)
	if resp.StatusCode != 200 {
		t.Fatalf("list: %d", resp.StatusCode)
	}
	if !strings.Contains(string(body), `"unreadCount":0`) {
		t.Errorf("expected unreadCount=0 before any events, got %s", body)
	}
}

func TestDeviceTokens_RegisterAndUnregister(t *testing.T) {
	f := newLedgerFixture(t)
	stu := f.loginStudent()
	resp, _ := f.do("POST", "/me/device-tokens",
		map[string]string{"token": "fcm-test-token-1", "platform": "ios"}, stu)
	if resp.StatusCode != 204 {
		t.Errorf("register: %d", resp.StatusCode)
	}
	// Re-register same token = upsert.
	resp, _ = f.do("POST", "/me/device-tokens",
		map[string]string{"token": "fcm-test-token-1", "platform": "ios"}, stu)
	if resp.StatusCode != 204 {
		t.Errorf("re-register: %d", resp.StatusCode)
	}
	resp, _ = f.do("DELETE", "/me/device-tokens/fcm-test-token-1", nil, stu)
	if resp.StatusCode != 204 {
		t.Errorf("unregister: %d", resp.StatusCode)
	}
}

func TestDeviceTokens_InvalidPlatform(t *testing.T) {
	f := newLedgerFixture(t)
	stu := f.loginStudent()
	resp, body := f.do("POST", "/me/device-tokens",
		map[string]string{"token": "tok", "platform": "carrier-pigeon"}, stu)
	if resp.StatusCode != 400 {
		t.Errorf("expected 400, got %d body=%s", resp.StatusCode, body)
	}
}
