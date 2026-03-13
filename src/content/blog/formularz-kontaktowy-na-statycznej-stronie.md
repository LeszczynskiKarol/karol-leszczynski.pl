---
title: "Formularz kontaktowy na statycznej stronie — Lambda, SES, S3 i zero backendu"
description: "Jak dodać formularz kontaktowy z załącznikami do strony na S3 + CloudFront, nie uruchamiając żadnego serwera. Dwie Lambdy (contact + presign), SES do emaili, S3 presigned URLs do uploadu plików, API Gateway jako endpoint. Koszt: ułamek centa miesięcznie. Z pełnym kodem produkcyjnym i skryptem setup."
pubDate: 2026-03-13
heroImage: "/images/blog/lambda-contact-form.jpg"
heroImageAlt: "Schemat architektury formularza kontaktowego: przeglądarka → API Gateway → Lambda → SES"
category: "seo-techniczne"
tags:
  [
    "aws",
    "lambda",
    "ses",
    "s3",
    "formularz-kontaktowy",
    "serverless",
    "astro",
    "api-gateway",
    "presigned-url",
  ]
draft: false
author: "Karol Leszczyński"
pillar: false
relatedPosts:
  [
    "jak-zbudowalem-15-stron-astro-aws-case-study",
    "aws-infrastruktura-25-domen-praktyczny-przewodnik",
  ]
---

Stawiasz stronę na S3 + CloudFront. Ładuje się w 200ms, kosztuje centów miesięcznie, skaluje się do miliona requestów. Potem klient pyta: „a formularz kontaktowy?".

I tu zaczynają się problemy. S3 serwuje pliki statyczne — nie przetwarza requestów POST. CloudFront jest CDN-em, nie application serwerem. Nie ma backendu, nie ma bazy danych, nie ma procesu, który mógłby odebrać formularz i wysłać email.

Klasyczne rozwiązania to albo zewnętrzna usługa (Formspree, Getform, Netlify Forms — płatne lub z limitem), albo postawienie serwera tylko po to, żeby obsługiwać jeden formularz (absurdalnie drogie w porównaniu ze stroną za $0.01/miesiąc). Albo embedowanie formularza Google (brzydkie, brak kontroli, brak załączników).

Moje rozwiązanie: dwie funkcje AWS Lambda (łącznie ~140 linii kodu), API Gateway HTTP API, SES do wysyłki emaili i S3 z presigned URLs do załączników. Koszt miesięczny: ułamek centa. Zero serwera. Zero utrzymania.

W tym artykule pokażę pełną implementację — od frontendu przez Lambdy po skrypt, który stawia całą infrastrukturę jedną komendą.

## Architektura — co się dzieje, kiedy użytkownik kliknie „wyślij"

Formularz działa w trzech krokach, z których dwa są opcjonalne (tylko jeśli użytkownik dodał załączniki).

Krok pierwszy (opcjonalny): jeśli są załączniki, frontend wysyła request POST na `/presign` z nazwą pliku, typem MIME i rozmiarem. Lambda presign waliduje plik (rozmiar, rozszerzenie), generuje unikalny klucz S3 (`uploads/2026-03-13/a1b2c3d4-brief.pdf`) i zwraca presigned URL. Frontend uploaduje plik bezpośrednio na S3 PUT-em na ten URL — plik nie przechodzi przez Lambda, idzie prosto z przeglądarki do S3. Powtórz dla każdego załącznika.

Krok drugi: frontend wysyła request POST na `/contact` z danymi formularza (imię, email, wiadomość, opcjonalnie telefon, typ projektu, budżet) oraz listą załączników (klucz S3, nazwa, rozmiar). Lambda contact waliduje dane, generuje presigned URL do pobrania każdego załącznika (ważne 7 dni), buduje email HTML i wysyła go przez SES.

Krok trzeci: SES dostarczam email na mój adres z danymi formularza, linkami do pobrania załączników i przyciskiem „Odpowiedz na zapytanie".

Cała komunikacja: przeglądarka → API Gateway → Lambda → SES/S3. Zero serwera w tle. Lambda startuje na request i wyłącza się po odpowiedzi.

## Lambda 1: Presigned URL do uploadu plików

Presigned URL to mechanizm AWS, który pozwala przeglądarce uploadować plik bezpośrednio na S3 bez przesyłania go przez backend. Lambda generuje podpisany URL (ważny 10 minut), który autoryzuje jeden konkretny upload na jeden konkretny klucz S3. Przeglądarka robi PUT na ten URL z plikiem w body — S3 akceptuje, bo podpis się zgadza.

Dlaczego nie uploadować przez Lambda? Bo Lambda ma limit 6 MB na payload (w API Gateway). Plik 8 MB PDF nie przejdzie. Presigned URL omija ten limit — plik idzie prosto z przeglądarki do S3, Lambda generuje tylko 200-bajtowy URL.

```javascript
// aws-lambdas/presign-upload/index.mjs
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { randomUUID } from "crypto";

const s3 = new S3Client({ region: process.env.AWS_REGION || "eu-central-1" });
const BUCKET = process.env.BUCKET_NAME || "karol-leszczynski-attachments";

const MAX_SIZE = 10 * 1024 * 1024; // 10 MB
const ALLOWED_EXTENSIONS = [
  ".pdf",
  ".doc",
  ".docx",
  ".txt",
  ".rtf",
  ".odt",
  ".jpg",
  ".jpeg",
  ".png",
  ".gif",
  ".webp",
  ".svg",
  ".pptx",
  ".xlsx",
  ".xls",
  ".csv",
  ".zip",
  ".rar",
  ".7z",
  ".md",
  ".html",
];

export const handler = async (event) => {
  // ... CORS headers ...

  const { filename, contentType, size } = JSON.parse(event.body || "{}");

  // Walidacja: rozmiar, rozszerzenie
  if (size && size > MAX_SIZE) {
    return {
      statusCode: 400,
      headers,
      body: JSON.stringify({ error: "Plik za duży (maks. 10 MB)" }),
    };
  }
  const ext = "." + filename.split(".").pop().toLowerCase();
  if (!ALLOWED_EXTENSIONS.includes(ext)) {
    return {
      statusCode: 400,
      headers,
      body: JSON.stringify({ error: "Niedozwolony format pliku." }),
    };
  }

  // Unikalny klucz: uploads/2026-03-13/a1b2c3d4-brief.pdf
  const date = new Date().toISOString().slice(0, 10);
  const uuid = randomUUID().slice(0, 8);
  const safeFilename = filename.replace(/[^a-zA-Z0-9._-]/g, "_");
  const key = `uploads/${date}/${uuid}-${safeFilename}`;

  const command = new PutObjectCommand({
    Bucket: BUCKET,
    Key: key,
    ContentType: contentType,
  });
  const uploadUrl = await getSignedUrl(s3, command, { expiresIn: 600 });

  return { statusCode: 200, headers, body: JSON.stringify({ uploadUrl, key }) };
};
```

Walidacja rozszerzeń działa po stronie Lambda, nie tylko po stronie frontendu. Frontend ma `accept=".pdf,.doc,..."` na input file — ale to tylko sugestia dla przeglądarki, łatwa do obejścia. Lambda sprawdza ponownie, bo to ona generuje autoryzację do uploadu.

Klucz S3 zawiera datę i UUID — dzięki temu nie ma kolizji nazw i łatwo znaleźć załączniki z konkretnego dnia. `safeFilename` usuwa polskie znaki i spacje, bo S3 klucze z niestandardowymi znakami powodują problemy z presigned URLs.

## Lambda 2: Przetwarzanie formularza i wysyłka emaila

Druga Lambda odbiera dane formularza, generuje linki do pobrania załączników i wysyła email przez SES.

```javascript
// aws-lambdas/contact-form/index.mjs
import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";
import { S3Client, GetObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const SES_REGION = "us-east-1"; // SES production w N. Virginia
const ses = new SESClient({ region: SES_REGION });
const s3 = new S3Client({ region: process.env.AWS_REGION || "eu-central-1" });
const BUCKET = process.env.BUCKET_NAME || "karol-leszczynski-attachments";

export const handler = async (event) => {
  const {
    name,
    email,
    phone,
    message,
    serviceType,
    website,
    budget,
    attachments,
  } = JSON.parse(event.body);

  // Walidacja wymaganych pól
  if (!name || !email || !message) {
    return {
      statusCode: 400,
      headers,
      body: JSON.stringify({ error: "Brak wymaganych pól" }),
    };
  }
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return {
      statusCode: 400,
      headers,
      body: JSON.stringify({ error: "Nieprawidłowy adres email" }),
    };
  }

  // Generuj linki do pobrania załączników (ważne 7 dni)
  let attachmentsHtml = "";
  if (attachments && attachments.length > 0) {
    const links = [];
    for (const att of attachments) {
      const url = await getSignedUrl(
        s3,
        new GetObjectCommand({ Bucket: BUCKET, Key: att.key }),
        { expiresIn: 7 * 24 * 3600 }, // 7 dni
      );
      links.push(`<li><a href="${url}">${att.name}</a>
        (${fmtSize(att.size)})</li>`);
    }
    attachmentsHtml = `<tr>
      <td>Załączniki:</td>
      <td><ul>${links.join("")}</ul>
        <p>Linki ważne 7 dni</p></td>
    </tr>`;
  }

  // Wyślij email przez SES
  await ses.send(
    new SendEmailCommand({
      Source: `Karol-Leszczynski.pl <formularz@karol-leszczynski.pl>`,
      Destination: { ToAddresses: ["kontakt@karol-leszczynski.pl"] },
      ReplyToAddresses: [email], // "Odpowiedz" idzie do klienta
      Message: {
        Subject: {
          Data: `Nowe zapytanie: ${name}${serviceType ? " — " + serviceType : ""}`,
        },
        Body: { Html: { Data: htmlBody } },
      },
    }),
  );

  return { statusCode: 200, headers, body: JSON.stringify({ success: true }) };
};
```

Ważny detal: `ReplyToAddresses: [email]`. Kiedy dostaję email z formularza i klikam „Odpowiedz" w Gmailu — odpowiedź idzie do klienta, nie do `formularz@karol-leszczynski.pl`. Dzięki temu nie muszę ręcznie kopiować adresu.

SES działa w regionie `us-east-1` (N. Virginia), choć Lambdy są w `eu-central-1` (Frankfurt). To dlatego, że SES production approval robiłem w N. Virginia — i nie ma powodu przenosić, bo SES i tak dostarcza email w sekundy niezależnie od regionu.

Dwa osobne klienty AWS SDK — `SESClient` z regionem `us-east-1` i `S3Client` z regionem `eu-central-1` — to intencjonalny design. Każdy serwis w swoim regionie.

## Frontend — upload sekwencyjny, nie równoległy

Frontend to vanilla JavaScript (bez frameworka) osadzony w stronie Astro. Kluczowa decyzja: pliki uploadują się sekwencyjnie, nie równolegle.

```javascript
// Fragment z kontakt/index.astro
var atts = [],
  chain = Promise.resolve();
if (files.length > 0) {
  uploadProgress.style.display = "flex";
  files.forEach(function (f, idx) {
    chain = chain.then(function () {
      uploadStatus.textContent =
        "Przesyłanie pliku " + (idx + 1) + " z " + files.length + "...";
      return uploadFile(f).then(function (r) {
        atts.push(r);
      });
    });
  });
}
chain.then(function () {
  // Wszystkie pliki przesłane → wyślij formularz
  return fetch(API_URL + "/contact", {
    method: "POST",
    body: JSON.stringify({ name, email, message, attachments: atts }),
  });
});
```

Dlaczego sekwencyjnie? Bo presigned URL jest generowany per plik (osobny request do Lambda). Przy 5 plikach równolegle: 5 requestów do presign + 5 PUT-ów do S3 jednocześnie. To 10 połączeń naraz z przeglądarki, co na wolnym łączu powoduje timeouty. Sekwencyjnie: 2 requesty na plik, jeden po drugim, z progress barem pokazującym „Przesyłanie pliku 2 z 5".

Funkcja `uploadFile` to dwa kroki — presign, potem PUT:

```javascript
function uploadFile(file) {
  // Krok 1: Pobierz presigned URL z Lambda
  return fetch(API_URL + "/presign", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      filename: file.name,
      contentType: file.type || "application/octet-stream",
      size: file.size,
    }),
  })
    .then(function (r) {
      return r.json();
    })
    .then(function (d) {
      // Krok 2: Upload pliku prosto na S3
      return fetch(d.uploadUrl, {
        method: "PUT",
        headers: { "Content-Type": file.type || "application/octet-stream" },
        body: file, // plik idzie prosto do S3, nie przez Lambda
      }).then(function () {
        return { key: d.key, name: file.name, size: file.size };
      });
    });
}
```

Frontend ma też drag & drop na dropzone, deduplikację plików (po nazwie + rozmiarze), walidację rozmiaru (10 MB) i liczby (max 5), oraz renderowanie listy dodanych plików z możliwością usunięcia. To wszystko w ~90 linii vanilla JS bez żadnej biblioteki.

## Infrastruktura — jeden skrypt stawia wszystko

Mam skrypt `setup-aws.sh`, który tworzy całą infrastrukturę jedną komendą. Odpala się raz — potem Lambdy aktualizuję osobnym skryptem.

Co robi `setup-aws.sh` krok po kroku:

Tworzy bucket S3 na załączniki z CORS (żeby przeglądarka mogła robić PUT na presigned URL) i lifecycle rule (automatyczne usuwanie plików po 30 dniach — nie chcę trzymać załączników klientów w nieskończoność).

```bash
# Lifecycle — automatyczne usuwanie załączników po 30 dniach
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration '{
    "Rules": [{
      "ID": "DeleteUploadsAfter30Days",
      "Filter": {"Prefix": "uploads/"},
      "Status": "Enabled",
      "Expiration": {"Days": 30}
    }]
  }'
```

Tworzy rolę IAM z politykami: `AWSLambdaBasicExecutionRole` (logi do CloudWatch) + inline policy na S3 PutObject/GetObject i SES SendEmail.

Tworzy dwie Lambdy: `presign` (128 MB RAM, timeout 15s) i `contact` (256 MB RAM, timeout 30s). Contact dostaje więcej pamięci, bo parsuje HTML i komunikuje się z dwoma serwisami (S3 + SES).

Tworzy HTTP API w API Gateway z dwoma route'ami (POST `/presign`, POST `/contact`) i konfiguracją CORS. API Gateway to ten element, który daje publiczny URL — Lambdy same w sobie nie mają endpointu HTTP.

```bash
# Integracja Lambda z API Gateway — per endpoint
for FUNC in presign contact; do
  FUNC_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${PREFIX}-${FUNC}"

  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri "$FUNC_ARN" \
    --payload-format-version "2.0" \
    --query 'IntegrationId' --output text)

  aws apigatewayv2 create-route \
    --api-id "$API_ID" \
    --route-key "POST /${FUNC}" \
    --target "integrations/${INTEGRATION_ID}"
done
```

Na końcu skrypt wypisuje URL API, który trzeba wkleić do strony kontaktowej. Drugi skrypt — `update-lambdas.sh` — pakuje kod do ZIP i aktualizuje Lambdy po zmianach. Przyjmuje argument: `./update-lambdas.sh presign`, `./update-lambdas.sh contact` lub `./update-lambdas.sh all`.

## CORS — trzy warstwy, bo jedna nie wystarczy

CORS to największa pułapka w tym setupie. Przeglądarka musi mieć pozwolenie na request z `karol-leszczynski.pl` do `execute-api.eu-central-1.amazonaws.com` (inny origin). To pozwolenie musi być skonfigurowane w trzech miejscach.

Pierwszy: API Gateway. Konfiguracja CORS na poziomie HTTP API — `AllowOrigins`, `AllowMethods: POST, OPTIONS`, `AllowHeaders: Content-Type`.

Drugi: Lambda. Każda Lambda zwraca nagłówki CORS w response (na wypadek, gdyby API Gateway je nie dodał — co się zdarza przy błędach 5xx). Plus obsługa preflight `OPTIONS` — przeglądarka wysyła OPTIONS przed każdym POST z niestandardowymi headerami.

```javascript
// Każda Lambda ma to na początku
const ALLOWED_ORIGINS = [
  "https://www.karol-leszczynski.pl",
  "https://karol-leszczynski.pl",
  "http://localhost:4321", // dev
];
const origin = event.headers?.origin || "";
const allowOrigin = ALLOWED_ORIGINS.includes(origin)
  ? origin
  : "https://www.karol-leszczynski.pl";
```

Trzeci: bucket S3 dla załączników. Przeglądarka robi PUT bezpośrednio na S3 (presigned URL) — to cross-origin request z perspektywy przeglądarki. Bez CORS na buckecie S3 upload się nie powiedzie.

```bash
aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration '{
  "CORSRules": [{
    "AllowedOrigins": [
      "https://www.karol-leszczynski.pl",
      "https://karol-leszczynski.pl",
      "http://localhost:4321"
    ],
    "AllowedMethods": ["PUT", "GET"],
    "AllowedHeaders": ["*"],
    "MaxAgeSeconds": 3600
  }]
}'
```

Pominiesz jeden z trzech — formularz będzie działał na localhost, ale nie na produkcji. Albo odwrotnie. Albo formularz zadziała, ale upload plików nie. Debugowałem CORS w tym setupie kilka godzin, zanim odkryłem, że potrzebuję wszystkich trzech warstw.

## Bezpieczeństwo — co blokuję i dlaczego

Walidacja działa na trzech poziomach.

Na frontendzie: `accept` na input file (ogranicza wybór plików w eksploratorze), limit 5 plików, limit 10 MB per plik, deduplikacja. To „miękka" walidacja — użytkownik nie musi trafiać na błąd z Lambda.

Na Lambda presign: whitelist rozszerzeń (18 typów), limit rozmiaru, sanityzacja nazwy pliku (usunięcie znaków specjalnych). Jeśli ktoś spróbuje uploadować `.exe` — Lambda zwróci 400 bez generowania presigned URL. Plik nie trafi na S3.

Na Lambda contact: walidacja wymaganych pól, walidacja formatu email regexem, escape HTML w danych (`esc()` — zamiana `<`, `>`, `&`, `"` na encje). Bez escape klient mógłby wstrzyknąć HTML/JS do emaila — co jest wektorem ataku XSS na klienta pocztowego.

```javascript
function esc(str) {
  return String(str || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
```

Lifecycle rule na S3 automatycznie kasuje załączniki po 30 dniach. Linki do pobrania wygasają po 7 dniach (presigned GET URL). Nie trzymam plików klientów dłużej niż potrzebuję.

## Koszt — ile to kosztuje na produkcji

Lambda free tier: 1 milion requestów i 400 000 GB-sekund miesięcznie za darmo. Mój formularz kontaktowy dostaje kilka–kilkanaście zgłoszeń miesięcznie. To nawet nie zbliża się do 0.1% free tier. Koszt Lambda: $0.00.

API Gateway: $1.00 za milion requestów. Przy kilkudziesięciu requestach miesięcznie: $0.00.

S3: przechowywanie kilku MB załączników. Koszt: $0.00 (zaokrąglając).

SES: $0.10 za 1000 emaili. Przy 10 emailach: $0.001.

Łączny koszt formularza kontaktowego z załącznikami: poniżej jednego centa miesięcznie. Dla porównania: Formspree Pro to $10/miesiąc, Netlify Forms Pro to $19/miesiąc. Moje rozwiązanie kosztuje ~1000× mniej — ale wymaga jednorazowego setupu infrastruktury AWS.

## Kiedy ten wzorzec ma sens

Ten sam wzorzec (`presign Lambda` + `contact Lambda` + `API Gateway` + `SES`) stosuję na kilkunastu domenach. Zmieniam tylko adres email docelowy i nazwę domeny w CORS. Mam oddzielne Lambdy per domena (nie jedną współdzieloną), bo chcę izolacji — błąd w jednej nie wpłynie na inne, a logi w CloudWatch są per funkcja.

Wzorzec ma sens, kiedy masz statyczną stronę na S3/CloudFront (lub Netlify/Vercel, gdzie też nie masz backendu), kiedy potrzebujesz formularza z załącznikami (presigned URL rozwiązuje problem limitu 6 MB), kiedy chcesz pełnej kontroli nad wyglądem emaila (SES akceptuje dowolny HTML), i kiedy nie chcesz płacić za zewnętrzne usługi formularzy.

Nie ma sensu, kiedy masz już backend (Fastify, Express, Django — po prostu dodaj endpoint). Nie ma sensu, kiedy potrzebujesz zaawansowanej logiki po stronie serwera (np. zapis do bazy, integracja z CRM — wtedy lepiej postawić mikroserwis). I nie ma sensu, kiedy nie masz konta AWS — koszt wejścia (konfiguracja SES, IAM, API Gateway) jest nietrywialny za pierwszym razem.

Ale za drugim razem — mam skrypt, który robi to w 60 sekund.
