// contact-form/index.mjs
// Lambda: karol-leszczynski-contact
// Przetwarza formularz kontaktowy i wysyła email przez SES

import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const REGION = process.env.AWS_REGION || "eu-central-1";
const SES_REGION = "us-east-1"; // SES production account in N. Virginia
const ses = new SESClient({ region: SES_REGION });
const s3 = new S3Client({ region: REGION });

const BUCKET = process.env.BUCKET_NAME || "karol-leszczynski-attachments";
const TO_EMAIL = "kontakt@karol-leszczynski.pl";
const FROM_EMAIL = "formularz@karol-leszczynski.pl";
const FROM_NAME = "Karol-Leszczynski.pl";

const ALLOWED_ORIGINS = [
  "https://www.karol-leszczynski.pl",
  "https://karol-leszczynski.pl",
  "http://localhost:4321",
];

function esc(str) {
  return String(str || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fmtSize(bytes) {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
  return (bytes / 1048576).toFixed(1) + " MB";
}

export const handler = async (event) => {
  const origin = event.headers?.origin || "";
  const allowOrigin = ALLOWED_ORIGINS.includes(origin)
    ? origin
    : "https://www.karol-leszczynski.pl";

  const headers = {
    "Access-Control-Allow-Origin": allowOrigin,
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
  };

  if (event.requestContext?.http?.method === "OPTIONS") {
    return { statusCode: 200, headers, body: "" };
  }

  try {
    const body = JSON.parse(event.body || "{}");
    const {
      name,
      email,
      phone,
      message,
      serviceType,
      website,
      budget,
      attachments,
    } = body;

    if (!name || !email || !message) {
      return {
        statusCode: 400,
        headers,
        body: JSON.stringify({
          error: "Brak wymaganych pól (name, email, message)",
        }),
      };
    }

    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return {
        statusCode: 400,
        headers,
        body: JSON.stringify({ error: "Nieprawidłowy adres email" }),
      };
    }

    // Attachment download links (7 days)
    let attachmentsHtml = "";
    if (attachments && attachments.length > 0) {
      const links = [];
      for (const att of attachments) {
        try {
          const url = await getSignedUrl(
            s3,
            new GetObjectCommand({ Bucket: BUCKET, Key: att.key }),
            { expiresIn: 7 * 24 * 3600 },
          );
          links.push(
            `<li style="margin-bottom:4px"><a href="${url}" style="color:#3b82f6;text-decoration:underline">${esc(att.name)}</a> <span style="color:#8b9dc3;font-size:12px">(${fmtSize(att.size || 0)})</span></li>`,
          );
        } catch (err) {
          links.push(
            `<li>${esc(att.name)} — <em style="color:#8b9dc3">błąd generowania linku</em></li>`,
          );
        }
      }
      attachmentsHtml = `
        <tr>
          <td style="padding:12px 20px;font-weight:600;color:#e2e8f0;vertical-align:top;width:140px;border-bottom:1px solid #1e293b">Załączniki:</td>
          <td style="padding:12px 20px;color:#8b9dc3;border-bottom:1px solid #1e293b">
            <ul style="margin:0;padding-left:20px;list-style:none">${links.join("")}</ul>
            <p style="font-size:11px;color:#64748b;margin-top:6px">Linki ważne 7 dni</p>
          </td>
        </tr>`;
    }

    const dateStr = new Date().toLocaleDateString("pl-PL", {
      year: "numeric",
      month: "long",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
    });

    const htmlBody = `
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#0f1729">
  <div style="max-width:620px;margin:0 auto;padding:32px 16px">
    <div style="border-top:3px solid #3b82f6;padding-top:16px;margin-bottom:8px">
      <table style="width:100%"><tr>
        <td style="font-size:20px;font-weight:700;color:#e2e8f0;letter-spacing:-0.02em">
          <span style="display:inline-block;width:28px;height:28px;background:linear-gradient(135deg,#3b82f6,#06d6a0);color:#fff;text-align:center;line-height:28px;border-radius:6px;font-size:14px;font-weight:800;margin-right:8px;vertical-align:middle">K</span>
          Karol Leszczyński
        </td>
        <td style="text-align:right;font-size:10px;color:#64748b;letter-spacing:0.08em;text-transform:uppercase">Nowe zapytanie</td>
      </tr></table>
    </div>
    <div style="border-bottom:1px solid #1e293b;margin-bottom:24px"></div>

    <h1 style="font-size:22px;font-weight:700;color:#e2e8f0;margin:0 0 6px">Nowe zapytanie z formularza kontaktowego</h1>
    <p style="font-size:11px;color:#64748b;margin:0 0 24px;letter-spacing:0.04em">${dateStr}</p>

    <table style="width:100%;border-collapse:collapse;background:#162032;border:1px solid #1e293b;border-radius:8px">
      <tr><td style="padding:12px 20px;font-weight:600;color:#e2e8f0;width:140px;border-bottom:1px solid #1e293b">Nadawca:</td><td style="padding:12px 20px;color:#8b9dc3;border-bottom:1px solid #1e293b">${esc(name)}</td></tr>
      <tr><td style="padding:12px 20px;font-weight:600;color:#e2e8f0;border-bottom:1px solid #1e293b">Email:</td><td style="padding:12px 20px;border-bottom:1px solid #1e293b"><a href="mailto:${esc(email)}" style="color:#3b82f6;text-decoration:underline">${esc(email)}</a></td></tr>
      ${phone ? `<tr><td style="padding:12px 20px;font-weight:600;color:#e2e8f0;border-bottom:1px solid #1e293b">Telefon:</td><td style="padding:12px 20px;color:#8b9dc3;border-bottom:1px solid #1e293b">${esc(phone)}</td></tr>` : ""}
      ${serviceType ? `<tr><td style="padding:12px 20px;font-weight:600;color:#e2e8f0;border-bottom:1px solid #1e293b">Projekt:</td><td style="padding:12px 20px;border-bottom:1px solid #1e293b"><span style="background:rgba(59,130,246,0.15);color:#3b82f6;padding:3px 10px;font-size:13px;border-radius:4px;font-weight:600">${esc(serviceType)}</span></td></tr>` : ""}
      ${website ? `<tr><td style="padding:12px 20px;font-weight:600;color:#e2e8f0;border-bottom:1px solid #1e293b">Strona www:</td><td style="padding:12px 20px;border-bottom:1px solid #1e293b"><a href="${esc(website)}" style="color:#3b82f6;text-decoration:underline">${esc(website)}</a></td></tr>` : ""}
      ${budget ? `<tr><td style="padding:12px 20px;font-weight:600;color:#e2e8f0;border-bottom:1px solid #1e293b">Budżet:</td><td style="padding:12px 20px;color:#8b9dc3;border-bottom:1px solid #1e293b">${esc(budget)}</td></tr>` : ""}
      <tr><td style="padding:12px 20px;font-weight:600;color:#e2e8f0;vertical-align:top;border-bottom:1px solid #1e293b">Wiadomość:</td><td style="padding:12px 20px;color:#8b9dc3;line-height:1.65;border-bottom:1px solid #1e293b">${esc(message).replace(/\n/g, "<br>")}</td></tr>
      ${attachmentsHtml}
    </table>

    <div style="text-align:center;padding:28px 0">
      <a href="mailto:${esc(email)}?subject=Re: Zapytanie — karol-leszczynski.pl" style="display:inline-block;padding:12px 32px;background:#3b82f6;color:#fff;text-decoration:none;font-size:14px;font-weight:600;border-radius:8px">
        Odpowiedz na zapytanie →
      </a>
    </div>

    <div style="border-top:1px solid #1e293b;padding-top:12px;text-align:center">
      <p style="font-size:10px;color:#64748b;letter-spacing:0.06em;text-transform:uppercase">Formularz kontaktowy · karol-leszczynski.pl · Full-Stack Developer</p>
    </div>
  </div>
</body>
</html>`;

    await ses.send(
      new SendEmailCommand({
        Source: `${FROM_NAME} <${FROM_EMAIL}>`,
        Destination: { ToAddresses: [TO_EMAIL] },
        ReplyToAddresses: [email],
        Message: {
          Subject: {
            Data: `Nowe zapytanie: ${name}${serviceType ? " — " + serviceType : ""}`,
            Charset: "UTF-8",
          },
          Body: { Html: { Data: htmlBody, Charset: "UTF-8" } },
        },
      }),
    );

    return {
      statusCode: 200,
      headers,
      body: JSON.stringify({ success: true }),
    };
  } catch (error) {
    console.error("Contact form error:", error);
    return {
      statusCode: 500,
      headers,
      body: JSON.stringify({ error: "Błąd wysyłania wiadomości" }),
    };
  }
};
