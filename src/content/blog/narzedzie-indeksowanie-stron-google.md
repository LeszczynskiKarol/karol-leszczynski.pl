---
title: "Automatyczne powiadamianie Google o nowych stronach — jak zbudowałem serverless notifier na AWS Lambda, który indeksuje moje domeny w 48 godzin"
description: "Case study z budowy systemu automatycznego indeksowania: AWS Lambda + DynamoDB + Google Indexing API + Search Console API. Sitemap diffing, bulk submit, dashboard z URL Inspection API, integracja z deploy.sh i GitHub Actions. Koszt: $0/miesiąc. Jedna Lambda obsługuje 23 domen."
pubDate: 2026-03-28
heroImage: "/images/blog/google-indexing-notifier-architecture.jpg"
heroImageAlt: "Schemat architektury Google Indexing Notifier — Lambda, DynamoDB, Google APIs"
category: "seo-techniczne"
tags:
  [
    "google indexing api",
    "aws lambda",
    "dynamodb",
    "seo",
    "indeksowanie",
    "serverless",
    "automatyzacja",
    "case study",
  ]
draft: false
author: "Karol Leszczyński"
pillar: true
relatedPosts: ["seo-command-center"]
---

Dodajesz nowy artykuł na stronę. Budujesz Astro, wrzucasz na S3, invalidejesz CloudFront. Strona jest live. Wchodzisz na Google — nie ma jej. Sprawdzasz Google Search Console — "Discovered — currently not indexed". Czekasz dzień, dwa, tydzień. Dalej nie ma. Ręcznie submittujesz URL w Search Console. Czekasz. Po kilku dniach — zaindeksowana.

Pomnóż to przez 23 domen i kilkadziesiąt nowych stron miesięcznie.

Każdy deploy to potencjalnie kilka nowych URL-i w sitemapie. Każdy wymaga ręcznego wejścia w GSC, wklejenia URL-a, kliknięcia "Request indexing". Jedno na raz. Z rate limitem ~10 URL-i dziennie przez interfejs. Przy 65 stronach na jednej domenie — tydzień ręcznej pracy.

Zbudowałem system, który robi to automatycznie. Przy każdym deployu. Dla wszystkich domen. Zero ręcznej roboty. Koszt: $0 miesięcznie.

## Jak Google dowiaduje się o nowych stronach

Google ma trzy oficjalne ścieżki:

Crawl — Googlebot sam znajduje stronę, podążając za linkami. Czas: dni, tygodnie, miesiące. Dla nowych domen bez backlinków — może nigdy.

Sitemap — submittujesz sitemapę w Search Console. Google przetwarza ją "kiedy chce". Czas: godziny do tygodni. Brak gwarancji kolejności.

Indexing API — bezpośrednie powiadomienie: "ta strona jest nowa, zaindeksuj ją". Czas: minuty do 48 godzin. Oficjalnie przeznaczone dla stron z `JobPosting` i `BroadcastEvent`, ale w praktyce działa dla wszystkich typów stron. Limit: 200 URL-i dziennie per projekt Google Cloud.

Ping sitemap — klasyczny `curl https://www.google.com/ping?sitemap=...`. Zero autentykacji, zero konfiguracji, ale też zero gwarancji.

Chcę używać wszystkich czterech jednocześnie. Przy każdym deployu.

## Architektura — jedna Lambda na wszystkie domeny

<!-- SCREEN: Diagram architektury — deploy.sh → Lambda → (sitemap fetch, DynamoDB diff, Google Indexing API, Search Console API) -->

Cały system to jedna Lambda na AWS, która obsługuje wszystkie 23 domen. Nie trzeba nic stawiać per domena — dodajesz trzy linijki do deploy.sh i gotowe.

Komponenty:

**AWS Lambda** (`google-indexing-notifier`) — Node.js 22, ~200 linii kodu. Fetchuje sitemapę, diffuje z poprzednią wersją, wysyła powiadomienia do Google.

**DynamoDB** (`sitemap-url-tracker`) — przechowuje listę URL-i z ostatniego deployu per domena. Klucz: hostname domeny. Wartość: tablica URL-i + timestamp.

**DynamoDB** (`indexing-url-status`) — przechowuje statusy indeksowania per URL. Data pierwszego submittu, data ostatniego sprawdzenia, verdict z Google URL Inspection API.

**SSM Parameter Store** — klucz JSON Service Account Google. Bezpieczne przechowywanie w AWS, bez wrzucania credentiali do kodu.

**Google Service Account** — jedno konto serwisowe (`google-index-api@ageless-period-491209-s8.iam.gserviceaccount.com`) dodane jako Właściciel we wszystkich 23 domenach w Google Search Console.

Koszt: $0.00 miesięcznie. Lambda free tier (1M requestów/miesiąc, a używam ~50), DynamoDB on-demand free tier (25 RCU/WCU), SSM Parameter Store standard — gratis.

## Co dokładnie robi Lambda po każdym deployu

Dziewięć kroków, w tej kolejności:

**1. Ping sitemapy.** Natychmiastowy, bez autentykacji. `curl` do `google.com/ping?sitemap=...`. Sygnał dla Google że sitemap się zmienił.

**2. Fetch aktualnej sitemapy.** Lambda pobiera sitemapę z domeny. Obsługuje trzy formaty: sitemap-index.xml (index z listą sub-sitemap), sitemap.xml (flat list), i sitemap_0.xml (numerowane). Parsuje XML, wyciąga URL-e. Dla praca-magisterska.pl — 65 URL-i.

**3. Pobranie poprzedniej wersji z DynamoDB.** Klucz: hostname domeny (np. `www.praca-magisterska.pl`). Wartość: lista URL-i z ostatniego deployu.

**4. Diff.** Nowe URL-e = obecne w sitemapie, nieobecne w DynamoDB. Usunięte URL-e = obecne w DynamoDB, nieobecne w sitemapie. Pierwszy deploy domeny — wszystkie URL-e traktowane jako nowe.

**5. Autentykacja Google.** Lambda pobiera klucz Service Account z SSM Parameter Store, generuje JWT token (RS256), wymienia go na access token przez OAuth2. Ręcznie zaimplementowane, bez zależności od `googleapis` — mniejszy cold start.

**6. Submit sitemapy do Search Console API.** `PUT /webmasters/v3/sites/{siteUrl}/sitemaps/{feedpath}`. Informuje GSC o aktualnej sitemapie. Osobny od pingu — to oficjalny submit.

**7. Powiadomienie o nowych URL-ach.** Dla każdego nowego URL-a: `POST /v3/urlNotifications:publish` z `type: "URL_UPDATED"`. Rate limit: 200/dzień per projekt Google Cloud. Przy dużych batchach — 200ms delay między requestami.

**8. Powiadomienie o usuniętych URL-ach.** Analogicznie, z `type: "URL_DELETED"`. Google usunie stronę z indeksu.

**9. Zapis stanu.** Aktualna lista URL-i → DynamoDB. Przy następnym deployu — diff będzie precyzyjny.

Lambda zapisuje też `firstSubmitted` per URL do tabeli `indexing-url-status` — żeby dashboard wiedział kiedy URL został po raz pierwszy zgłoszony.

## Jak wygląda integracja z deploy

Trzy linijki na końcu `deploy.sh`:

```bash
echo "🔍 Notifying Google..."
curl -s "https://www.google.com/ping?sitemap=${SITE_URL}/sitemap-index.xml" > /dev/null
aws lambda invoke \
  --function-name google-indexing-notifier \
  --payload "{\"siteUrl\":\"${SITE_URL}\"}" \
  --cli-binary-format raw-in-base64-out \
  --region eu-central-1 indexing-result.json > /dev/null 2>&1
echo "  ✅ Google notified"
```

<!-- SCREEN: Terminal z outputem deploy.sh — build, S3 sync, CloudFront invalidation, "Google notified" na końcu -->

Dla GitHub Actions — ten sam invoke na końcu workflow:

```yaml
- run: |
    aws lambda invoke \
      --function-name google-indexing-notifier \
      --payload '{"siteUrl":"https://www.domena.pl"}' \
      --cli-binary-format raw-in-base64-out \
      --region eu-central-1 \
      /tmp/indexing-result.json
```

To samo wywołanie. Czy deploy odpala się ręcznie z `deploy.sh`, czy automatycznie z GitHub Actions po commicie — Lambda dostaje ten sam sygnał.

## JWT bez zewnętrznych zależności

Nie używam `googleapis` ani `google-auth-library` w Lambdzie. Obie paczki są ciężkie — kilkaset kilobajtów, wolniejszy cold start. Zamiast tego — ręczna implementacja JWT z wbudowanym modułem `crypto` Node.js.

Lambda pobiera klucz SA z SSM, generuje JWT (header + payload + podpis RSA-SHA256), wysyła `POST` do `oauth2.googleapis.com/token`, dostaje access token. Żadnych zależności poza AWS SDK (które Lambda ma wbudowane).

Jedyne dependency w `package.json`:

```json
{
  "dependencies": {
    "@aws-sdk/client-dynamodb": "^3.700.0",
    "@aws-sdk/client-ssm": "^3.700.0"
  }
}
```

Dwie paczki. Obie z AWS SDK v3, modułowe — importujesz tylko to co używasz.

## Bulk index — jednorazowy submit wszystkich URL-i

Przy dodawaniu nowej domeny do systemu — DynamoDB jest pusta, więc pierwszy deploy wyśle WSZYSTKIE URL-e jako "nowe". Ale to może przekroczyć limit 200/dzień.

Dla domen z wieloma stronami (Stojan Shop — 1187 URL-i) robię to rozłożone w czasie. Skrypt `bulk-index.sh` czyści cache DynamoDB dla domeny i wywołuje Lambdę:

```bash
./bulk-index.sh https://www.silniki-elektryczne.com.pl
```

Lambda wyśle pierwsze 200 URL-i, reszta — następnego dnia po kolejnym bulk-index. Albo poczekam — przy regularnych deployach nowe strony będą submitowane automatycznie, po kilka na deploy.

Przy mniejszych domenach (praca-magisterska.pl — 65 URL-i) bulk-index chwycił wszystko za pierwszym razem. 65 URL-i → 65 statusów 200 od Google Indexing API → zero błędów.

<!-- SCREEN: Terminal z outputem bulk-index — "Found 65 URLs in sitemap", "+65 new", lista URL-i z ✅ -->

## Dashboard — śledzenie statusów indeksowania

<!-- SCREEN: Google Indexing Dashboard — tabela domen z liczbą URL-i, statusami PASS/PENDING/FAIL, ostatnim sprawdzeniem -->

Osobna Lambda (`google-indexing-dashboard`) serwuje API do dashboardu. Czyta dane z tabeli `indexing-url-status`, sprawdza statusy przez Google URL Inspection API, zapisuje wyniki.

Dashboard pokazuje: ile URL-i zgłoszono, ile zaindeksowanych (PASS), ile oczekujących (NEUTRAL/UNKNOWN), ile odrzuconych (FAIL). Per domena i łącznie.

URL Inspection API daje szczegółowe informacje: verdict (PASS/FAIL/NEUTRAL), coverage state, czas ostatniego crawla, czy robots.txt blokuje, czy strona jest w indeksie. Dokładnie to samo co w Search Console, ale programowo.

Te dane zintegrowałem później z [SEO Command Center](/blog/seo-command-center) — panelem do zarządzania wszystkimi 23 domenami. Import z DynamoDB do PostgreSQL, wyświetlanie w tabelach z filtrowaniem i verdictami.

## Dodawanie nowej domeny — trzy minuty

Infrastruktura jest wspólna. Lambda, DynamoDB, SSM — jedno na wszystko. Dla nowej domeny:

1. Dodaj `google-index-api@ageless-period-491209-s8.iam.gserviceaccount.com` jako **Właściciela** w Google Search Console nowej domeny. Właściciel, nie Pełny użytkownik — API wymaga najwyższych uprawnień.

2. Dodaj trzy linijki do `deploy.sh` (lub `deploy.yml` dla GitHub Actions) z odpowiednim `siteUrl`.

3. Opcjonalnie: `./bulk-index.sh https://www.nowa-domena.pl` żeby zasubmitować istniejące strony.

Przy następnym deployu Lambda automatycznie: sfetchuje sitemapę, utworzy bazę w DynamoDB, zasubmituje URL-e. Domena pojawi się w dashboardzie.

## Obsługa formatu sitemap

Astro generuje różne formaty sitemap w zależności od konfiguracji. Lambda parsuje wszystkie:

Sitemap index (`sitemap-index.xml`) — XML z listą sub-sitemap. Lambda fetchuje każdą sub-sitemapę i zbiera URL-e.

Flat sitemap (`sitemap.xml`) — bezpośrednia lista URL-i w jednym pliku.

Numerowane (`sitemap-0.xml`, `sitemap_0.xml`) — wariant z plugin-em `@astrojs/sitemap` który dzieli na pliki po 45000 URL-i.

Lambda próbuje trzech wariantów po kolei, zaczynając od sitemap-index.xml. Pierwszy który zwraca 200 i ma URL-e — wygrywa.

## Problemy i pułapki

**Git Bash na Windows konwertuje ścieżki.** SSM Parameter Store ścieżka `/google-indexing/service-account-key` zamieniała się na ścieżkę Windows. Fix: `MSYS_NO_PATHCONV=1` przed każdą komendą AWS CLI, albo podwójny slash `//google-indexing/...`.

**Limit 200 URL-i dziennie.** Quota resetuje się o północy Pacific Time (9:00 CET). Przy normalnych deployach (1-10 nowych URL-i) nigdy nie trafisz w limit. Problem tylko przy bulk-index wielu domen tego samego dnia.

**Indexing API oficjalnie dla JobPosting/BroadcastEvent.** Google rozluźnił to ograniczenie — w praktyce działa dla wszystkich typów stron. Ale nie ma gwarancji. Jeśli Google zaostrzył politykę — ping sitemap i Search Console API submit nadal działają.

**Service Account musi być Właścicielem.** Nie "Pełny użytkownik" — Właściciel. Różnica: Indexing API wymaga `webmasters.readonly` scope + owner permission. Z niższymi uprawnieniami dostaniesz 403.

**Cold start Lambdy.** Pierwszy invoke po dłuższym czasie bezczynności: ~2-3s. Kolejne: ~200-500ms. Przy deployu nie ma to znaczenia — deploy sam trwa kilkadziesiąt sekund.

## Porównanie z istniejącymi narzędziami

Na GitHubie jest kilka popularnych rozwiązań: `google-indexing-script` (goenning), `request-indexing` (harlan-zw), `action-google-indexing` (robingenz). Wszystkie robią mniej więcej to samo — parsują sitemapę i submitują URL-e przez Indexing API.

Różnica w moim podejściu: **sitemap diffing**. Tamte narzędzia submitują wszystkie URL-e z sitemapy za każdym razem. Moja Lambda porównuje z poprzednią wersją i wysyła tylko nowe/usunięte. Przy domenie z 1187 stronami i 3 nowymi — wysyłam 3 requesty, nie 1187.

Druga różnica: **serverless**. Tamte narzędzia wymagają ręcznego uruchomienia lub osobnego crona. Moja Lambda jest częścią pipeline'u deploy — odpala się automatycznie po każdym `git push`.

Trzecia różnica: **multi-domain**. Jedna Lambda, jedna tabela DynamoDB, jeden klucz SA. Dla każdej nowej domeny — trzy linijki w deploy.sh. Nie trzeba konfigurować osobnych instancji.

## Co dalej

System działa w produkcji na 23 domenach. Wbiega w codzienną rutynę — deploy odpala Lambdę, Lambda diffuje sitemapę, Google dostaje powiadomienie, strona jest w indeksie w ciągu 24-48 godzin.

Dane o statusach indeksowania zaciągam do [SEO Command Center](/blog/seo-command-center) — własnego panelu analitycznego który agreguje GSC, linki, pozycje i statusy indeksowania z wszystkich domen w jednym dashboardzie.

Potencjalne rozszerzenia: integracja z IndexNow (Bing, Yandex — osobny protokół, prostszy niż Google Indexing API), retry logic per URL (jeśli Indexing API zwróci 429, retry następnego dnia), i automatyczne sprawdzanie statusów URL Inspection API dzień po submicie — żeby wiedzieć natychmiast czy Google zaindeksował stronę, bez ręcznego sprawdzania w GSC.

## Kiedy warto budować własne

Własny notifier ma sens kiedy masz wiele domen z regularnymi deployami, infrastrukturę na AWS (Lambda + DynamoDB = naturalny wybór), i chcesz zero ręcznej pracy po deploy.

Nie ma sensu kiedy masz jedną domenę i deploye raz na miesiąc — wtedy ręczny submit w GSC jest wystarczający. Albo kiedy nie masz AWS — wtedy `google-indexing-script` z GitHub Actions cron jest prostszym rozwiązaniem.

Mój system to 200 linii kodu Lambda, 2 tabele DynamoDB, 1 parametr SSM. Deploy infrastruktury jednorazowo skryptem bash. Dodanie nowej domeny — trzy minuty. Koszt — zero. A strony są w Google zanim zdążę sprawdzić czy deploy się udał.
