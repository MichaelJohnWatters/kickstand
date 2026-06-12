-- 0006: Add a tiny inline thumbnail to expenses.
--
-- The list endpoints (/me/expenses and /expenses for review) carry a
-- base64'd 50×50 JPEG of the receipt so the manager review queue
-- shows a real preview without an extra HTTP fetch per row. Around
-- 1–2 KB per receipt; trivial DB-size impact.
--
-- The full image still lives in the file-store (Local today,
-- Firebase Storage / GCS post-deploy) and is fetched on modal open
-- via GET /expenses/{id}/receipt.

ALTER TABLE expenses ADD COLUMN receipt_thumb BLOB;
