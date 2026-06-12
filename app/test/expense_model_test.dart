// Receipt + Expense model tests.
//
// Receipts have two pieces of binary data attached:
//   1. A 50×50 thumbnail the server inlines as base64 in list payloads.
//   2. The full image, fetched on demand via /expenses/{id}/receipt.
//
// These tests cover the model decoding for (1): does Expense.fromJson
// correctly parse the receiptThumb field across the happy path
// (well-formed base64 JPEG), the missing-field path (older rows),
// and the malformed path (server sends garbage we should tolerate).
// (2) is just an HTTP fetch — covered by the receipts_test.go suite
// on the backend.

import 'package:flutter_test/flutter_test.dart';
import 'package:kickstand/api/models.dart';

Map<String, dynamic> _baseExpenseJson({Object? thumb}) => {
      'id': 'exp_1',
      'instructorId': 'user_instr',
      'instructorName': 'Dave',
      'categoryId': 'petrol',
      'categoryLabel': 'Petrol',
      'categoryIcon': 'fuel',
      'categoryTone': 277,
      'amountPence': 3200,
      'occurredAt': '2026-06-08T10:00:00Z',
      'where': 'Local',
      'notes': '',
      'status': 'pending',
      'receiptContentType': 'image/jpeg',
      'receiptSizeBytes': 24000,
      if (thumb != null) 'receiptThumb': thumb,
      'submittedAt': '2026-06-08T10:05:00Z',
      'reviewedByName': '',
      'reviewerNote': '',
      'paidByName': '',
      'paidMethod': '',
    };

void main() {
  group('Expense.fromJson — receiptThumb', () {
    test('happy path: decodes base64 into bytes', () {
      // Tiny "JPEG-shaped" payload — 3 bytes is enough to assert
      // base64 round-trip. The renderer can sanity-check it's a JPEG
      // by inspecting magic bytes separately.
      const b64 = '/9j/4Q=='; // 0xFF 0xD8 0xFF 0xE1 — JPEG magic
      final e = Expense.fromJson(_baseExpenseJson(thumb: b64));
      expect(e.receiptThumbBytes, isNotEmpty);
      expect(e.receiptThumbBytes.length, 4);
      expect(e.receiptThumbBytes[0], 0xFF);
      expect(e.receiptThumbBytes[1], 0xD8);
      expect(e.receiptThumbBytes[2], 0xFF);
    });

    test('field absent (older row): empty bytes', () {
      final e = Expense.fromJson(_baseExpenseJson());
      expect(e.receiptThumbBytes, isEmpty,
          reason: 'rows submitted before migration 0006 have no thumb');
    });

    test('field empty string: empty bytes', () {
      final e = Expense.fromJson(_baseExpenseJson(thumb: ''));
      expect(e.receiptThumbBytes, isEmpty);
    });

    test('field is null: empty bytes', () {
      final e = Expense.fromJson(_baseExpenseJson(thumb: null));
      expect(e.receiptThumbBytes, isEmpty);
    });

    test('malformed base64: empty bytes (no crash)', () {
      // The server should never send this, but a defensive decode keeps
      // a regression on the backend from crashing the entire list
      // screen.
      final e = Expense.fromJson(_baseExpenseJson(thumb: '!!!not base64!!!'));
      expect(e.receiptThumbBytes, isEmpty);
    });

    test('non-string type: empty bytes', () {
      final e = Expense.fromJson(_baseExpenseJson(thumb: 12345));
      expect(e.receiptThumbBytes, isEmpty);
    });
  });

  group('Expense.fromJson — basics', () {
    test('parses core fields', () {
      final e = Expense.fromJson(_baseExpenseJson());
      expect(e.id, 'exp_1');
      expect(e.amountPence, 3200);
      expect(e.status, 'pending');
      expect(e.categoryLabel, 'Petrol');
      expect(e.receiptContentType, 'image/jpeg');
      expect(e.receiptSizeBytes, 24000);
    });

    test('forgiving of missing fields', () {
      // The model has to survive backend evolution.
      final e = Expense.fromJson({'id': 'x'});
      expect(e.id, 'x');
      expect(e.amountPence, 0);
      expect(e.status, 'pending');
      expect(e.receiptThumbBytes, isEmpty);
    });
  });
}
