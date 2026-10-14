// Package email is the outbound-email seam: a small Sender interface with an
// SMTP implementation (SendGrid/SES/Mailgun/Postmark all speak SMTP) and a
// dev log stand-in. The notify email worker (notify.DispatchEmails) renders
// messages and hands them to a Sender; nothing else talks SMTP directly.
package email

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/smtp"
	"strings"
	"time"
)

// Message is one plain-text email. HTML is deliberately out of scope for now —
// plain text is enough for confirmations/reminders and sidesteps a templating
// dependency.
type Message struct {
	To      string
	ToName  string
	Subject string
	Body    string
}

// Sender delivers a Message. Implementations must be safe for sequential use
// by the single email worker goroutine.
type Sender interface {
	Send(ctx context.Context, m Message) error
}

// SMTPSender relays through a standard SMTP server. smtp.SendMail upgrades to
// STARTTLS automatically when the server advertises it.
type SMTPSender struct {
	Host     string
	Port     string
	Username string
	Password string
	From     string
	FromName string
}

func (s *SMTPSender) Send(_ context.Context, m Message) error {
	var auth smtp.Auth
	if s.Username != "" {
		auth = smtp.PlainAuth("", s.Username, s.Password, s.Host)
	}
	addr := net.JoinHostPort(s.Host, s.Port)
	if err := smtp.SendMail(addr, auth, s.From, []string{m.To}, s.render(m)); err != nil {
		return fmt.Errorf("smtp send: %w", err)
	}
	return nil
}

func (s *SMTPSender) render(m Message) []byte {
	from := s.From
	if s.FromName != "" {
		from = fmt.Sprintf("%s <%s>", s.FromName, s.From)
	}
	to := m.To
	if m.ToName != "" {
		to = fmt.Sprintf("%s <%s>", m.ToName, m.To)
	}
	var b strings.Builder
	b.WriteString("From: " + from + "\r\n")
	b.WriteString("To: " + to + "\r\n")
	b.WriteString("Subject: " + m.Subject + "\r\n")
	b.WriteString("Date: " + time.Now().UTC().Format(time.RFC1123Z) + "\r\n")
	b.WriteString("MIME-Version: 1.0\r\n")
	b.WriteString("Content-Type: text/plain; charset=UTF-8\r\n")
	b.WriteString("\r\n")
	b.WriteString(m.Body)
	return []byte(b.String())
}

// LogSender logs instead of sending — the dev/staging stand-in (EMAIL_LOG=1)
// so the whole pipeline can be exercised without a real SMTP relay.
type LogSender struct{ Log *slog.Logger }

func (l LogSender) Send(_ context.Context, m Message) error {
	lg := l.Log
	if lg == nil {
		lg = slog.Default()
	}
	lg.Info("email (log sender — not actually sent)",
		slog.String("to", m.To), slog.String("subject", m.Subject))
	return nil
}
