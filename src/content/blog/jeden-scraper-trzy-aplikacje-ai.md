---
title: "Jeden scraper, trzy aplikacje AI — jak zbudowałem centralny mikroserwis do web researchu"
description: "Case study architektury centralnego scrapera (Python + Selenium + BeautifulSoup na AWS Elastic Beanstalk), który obsługuje trzy różne aplikacje AI: platformę do nauki matury, generator treści copywriterskich i generator prac akademickich. Z prawdziwym kodem, pipeline'ami i lekcjami z produkcji."
pubDate: 2026-03-13
heroImage: "/images/blog/scraper-architecture.jpg"
heroImageAlt: "Schemat architektury centralnego scrapera obsługującego trzy aplikacje AI"
category: "seo-techniczne"
tags:
  [
    "scraper",
    "python",
    "selenium",
    "ai",
    "mikroserwis",
    "architektura",
    "case study",
    "fastify",
    "claude-api",
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

Mam trzy aplikacje AI w produkcji. MaturaPolski.pl sprawdza wypracowania maturalne, przeszukując internet w poszukiwaniu wzorcowych interpretacji. Smart-Copy.ai generuje artykuły copywriterskie na podstawie źródeł z Google. Smart-Edu.ai pisze prace licencjackie i magisterskie z automatycznymi przypisami do prawdziwych publikacji. Wszystkie trzy mają jedno wspólne wymaganie: muszą przeczytać treść strony internetowej, zanim AI zacznie pracować.

Na początku każda aplikacja miała własny kod do scrapowania. Szybko okazało się, że to nie działa. Strony z frameworkami JavaScript (React, Next.js) zwracały pusty HTML. PDF-y nie były obsługiwane. Każda poprawka musiała być deployowana w trzech miejscach. Rozwiązanie: centralny scraper jako osobny mikroserwis, dostępny przez HTTP API.

## Architektura — jeden endpoint, trzy klienty

Scraper to aplikacja Python/Flask deployowana na AWS Elastic Beanstalk w regionie Sztokholm (eu-north-1). Działa na instancji t3.small z Gunicorn (2 workery) i nginx jako reverse proxy. Pod spodem cztery instancje headless Chrome (ChromeDriver), gotowe do renderowania stron z JavaScript.

API ma jeden endpoint: `POST /scrape` z JSON body `{ "url": "https://..." }`. Zwraca `{ "text": "wyciągnięty tekst..." }`. To wszystko. Prostota jest celowa — każda aplikacja-klient wie, co chce zescrapować i jak przetworzyć wynik. Scraper nie podejmuje decyzji biznesowych.

Trzy aplikacje konsumują ten endpoint w zupełnie różny sposób. MaturaPolski scrapuje 5 URL-i, żeby sprawdzić wypracowanie ucznia. Smart-Copy scrapuje 10–20 URL-i, żeby wygenerować artykuł. Smart-Edu scrapuje 30–45 URL-i per rozdział pracy akademickiej, z osobnym research flow na język polski i angielski.

## Scraper — jak działa od środka

Scraper rozwiązuje problem, który wygląda prosto, ale nie jest: wyciągnij tekst z dowolnego URL-a. „Dowolny" oznacza tutaj statyczną stronę HTML, aplikację SPA w React/Next.js/Vue, dokument PDF, plik DOCX i plik DOC (stary format Worda).

Kiedy request trafia do scrapera, pierwszym krokiem jest klasyfikacja. Scraper wysyła request HTTP z losowym User-Agent (biblioteka `fake_useragent`) i sprawdza Content-Type odpowiedzi. PDF, DOCX i DOC trafiają do dedykowanych parserów. HTML przechodzi przez detekcję SPA.

Detekcja SPA to heurystyka, nie magia. Scraper szuka wskaźników frameworków JavaScript w HTML: `__NEXT_DATA__`, `id="__next"`, `id="root"`, `self.__next_f`, odniesienia do webpack/nuxt/gatsby. Jeśli znajdzie dwa lub więcej wskaźników, albo jeśli HTML jest bardzo krótki (poniżej 500 znaków) i zawiera bundle JS — klasyfikuje stronę jako SPA i przełącza się na Selenium.

Detekcja SPA to prosta heurystyka — ale skuteczna w 95% przypadków:

```python
# application.py — detekcja SPA
def is_spa_website(html_content):
    spa_indicators = [
        'react', 'next.js', '_next', 'vue', 'angular',
        '__NEXT_DATA__', 'nuxt', 'gatsby', 'webpack',
        'self.__next_f', 'id="__next"', 'id="root"'
    ]
    html_lower = html_content.lower()
    spa_count = sum(
        1 for ind in spa_indicators if ind.lower() in html_lower
    )

    is_short_with_js = len(html_content) < 500 and any(
        ind in html_lower for ind in ['webpack', '_next', '__next']
    )
    return spa_count >= 2 or is_short_with_js
```

Dla zwykłych stron HTML wystarczy BeautifulSoup. Usuwa tagi `<script>`, `<style>` i `<noscript>`, wyciąga tekst metodą `get_text()`, czyści białe znaki i zwraca wynik. Szybko i tanio — request trwa 1–3 sekundy.

Dla SPA uruchamia się Selenium z headless Chrome. Timeout na załadowanie strony to 600 sekund (10 minut — niektóre strony akademickie ładują się bardzo wolno). Selenium czeka, aż `<body>` będzie miał więcej niż 100 znaków tekstu (WebDriverWait), a potem dodaje jeszcze 3 sekundy na dokładowanie asynchronicznych komponentów. Po renderowaniu HTML przechodzi przez ten sam pipeline czyszczenia co zwykłe strony. Request z Selenium trwa 5–30 sekund, czasem dłużej.

Dlaczego cztery instancje ChromeDriver? Bo Smart-Edu przy generowaniu pracy magisterskiej wysyła 30–45 requestów w krótkim czasie (trzy zapytania Google × 10 wyników × kilka rozdziałów). Bez puli ChromeDriverów requesty kolejkowałyby się i pipeline trwałby godziny zamiast minut.

## MaturaPolski — AI sprawdza wypracowania z pomocą internetu

MaturaPolski używa scrapera w procesie oceniania wypracowań maturalnych. Kiedy uczeń odpowiada na pytanie o lekturę, AI nie polega wyłącznie na swojej wiedzy treningowej — przeszukuje internet, żeby znaleźć wzorcowe interpretacje i sprawdzić fakty.

Pipeline oceny z web research składa się z pięciu kroków. Pierwszy krok to generowanie zapytania Google: Claude dostaje pytanie maturalne i odpowiedź ucznia, generuje krótkie zapytanie do wyszukiwarki (5–7 słów). Drugi krok to wyszukiwanie w Google Custom Search API — zwraca 5 najlepszych wyników. Trzeci krok to scrapowanie: serwis `WebScrapperService` wysyła URL-e do centralnego scrapera, scrapując do 3 równolegle (limit concurrency). Czwarty krok to agregacja — zescrapowane treści łączone są do maksymalnie 20 000 znaków z oznaczeniem źródeł. Piąty krok to ocena: Claude dostaje odpowiedź ucznia, pytanie i zescrapowane źródła — ocenia na ich podstawie.

Kluczowa zasada: AI ocenia wyłącznie na podstawie dostarczonych źródeł, nie na podstawie swojej pamięci treningowej. To eliminuje halucynacje — jeśli źródło nie potwierdza twierdzenia ucznia, AI nie może go uznać za poprawne.

MaturaPolski ma też fallback. Jeśli scraper nie zwróci wyników (serwis niedostępny, timeout, brak wyników w Google), system przechodzi na standardową ocenę bez web research. Uczeń dostaje ocenę, ale bez weryfikacji źródłowej — i informację, że ocena została przeprowadzona bez materiałów zewnętrznych.

Timeout w WebScrapperService to 120 sekund per request. Dla ucznia czekającego na ocenę wypracowania to akceptowalne — ale tylko dlatego, że UI pokazuje animację ładowania z informacją „Sprawdzam źródła...".

Klient scrapera w MaturaPolski — chunked concurrency i agregacja z limitem:

```typescript
// backend/src/services/webScrapperService.ts — klient scrapera
async scrapeMultipleUrls(
  urls: string[],
  concurrentLimit: number = 2,
) {
  const results: ScrapperResponse[] = [];

  for (let i = 0; i < urls.length; i += concurrentLimit) {
    const chunk = urls.slice(i, i + concurrentLimit);
    const chunkResults = await Promise.all(
      chunk.map((url) => this.scrapeUrl(url)),
    );
    results.push(...chunkResults);
  }

  return results;
}

aggregateScrapedContent(
  results: ScrapperResponse[],
  maxTotalLength = 50000,
) {
  let aggregated = "";
  for (const result of results.filter((r) => r.success && r.text)) {
    const cleaned = result.text
      .replace(/\s+/g, " ")
      .replace(/\n{3,}/g, "\n\n")
      .substring(0, 15000);
    aggregated += `\n\n=== ŹRÓDŁO: ${result.url} ===\n${cleaned}\n`;
    if (aggregated.length >= maxTotalLength) break;
  }
  return aggregated;
}
```

## Smart-Copy — generator treści z research pipeline

Smart-Copy to platforma do generowania artykułów copywriterskich. Klient zamawia tekst na zadany temat, z opcjonalnym SEO (frazy kluczowe, linki) i opcjonalnymi własnymi źródłami (URL-e, pliki PDF/DOCX). System generuje artykuł HTML o zadanej długości (od 1 000 do 300 000 znaków).

Pipeline generowania tekstu w Smart-Copy jest znacznie bardziej złożony niż w MaturaPolski. Składa się z sześciu etapów.

Etap pierwszy: Claude generuje zapytanie Google na podstawie tematu, rodzaju treści i języka. Etap drugi: Google Custom Search zwraca do 15 wyników. Etap trzeci: scraper scrapuje wszystkie 15 URL-i (nie tylko 5 jak w MaturaPolski). Timeout to 100 sekund dla źródeł Google, 300 sekund (5 minut) dla źródeł użytkownika — bo użytkownik podaje URL świadomie i oczekuje, że system go przeczyta. Etap czwarty: Claude analizuje zescrapowane treści i wybiera 3–8 najlepszych źródeł do pisania. Etap piąty: generowanie treści w jednym z trzech trybów (w zależności od długości). Etap szósty: post-processing z walidacją SEO, weryfikacją zakończenia i wstawianiem brakujących linków.

Trzy tryby generowania to kluczowy element architektury Smart-Copy. Teksty poniżej 10 000 znaków pisze jeden „pisarz" bezpośrednio. Teksty od 10 000 do 50 000 znaków przechodzą przez „kierownika" (Claude generuje strukturę HTML z nagłówkami H2/H3), a potem „pisarz" wypełnia strukturę treścią. Teksty powyżej 50 000 znaków dzielone są między wielu pisarzy — kierownik dzieli strukturę na równe części, a do 7 równoległych pisarzy generuje treść sekwencyjnie (każdy następny dostaje kontekst z poprzednich części).

Scraper w Smart-Copy obsługuje też źródła użytkownika — pliki PDF i DOCX uploadowane przez klienta. Te trafiają na S3 jako presigned URL-e, a potem scraper je pobiera i parsuje. Źródła użytkownika mają priorytet nad źródłami z Google — jeśli klient dał materiały, artykuł bazuje przede wszystkim na nich.

Problem z kontynuacją tekstu: Claude ma limit tokenów wyjściowych. Przy długich tekstach (50k+ znaków) odpowiedź zostaje ucięta (`stop_reason: "max_tokens"`). Smart-Copy rozwiązuje to pętlą kontynuacji — jeśli tekst jest ucięty, system wysyła Claude kontekst (ostatnie 3 000 znaków) z instrukcją „kontynuuj od miejsca przerwania". System sprawdza, które sekcje H2 ze struktury kierownika zostały już napisane, a które brakują — i instruuje Claude, żeby uzupełnił brakujące. Maksymalnie 3 próby kontynuacji per fragment.

## Smart-Edu — prace akademickie z per-chapter research

Smart-Edu to najbardziej zaawansowana z trzech aplikacji pod względem wykorzystania scrapera. Generuje prace licencjackie (3 rozdziały) i magisterskie (4 rozdziały) z automatycznymi przypisami, bibliografią i trójpoziomowym systemem referencji.

Pipeline Smart-Edu różni się od Smart-Copy jednym kluczowym elementem: research odbywa się per rozdział, nie per tekst. Dla pracy magisterskiej o marketingu cyfrowym system wykonuje osobny research dla rozdziału o SEO, osobny dla rozdziału o content marketingu, osobny dla rozdziału o analityce. Każdy rozdział dostaje dedykowane zapytania Google, dedykowane źródła i dedykowaną ewaluację jakości.

Na jeden rozdział system generuje trzy zapytania Google (jedno ogólne, jedno szczegółowe, jedno z modyfikatorem „pdf" — bo dokumenty PDF częściej są publikacjami akademickimi). Każde zapytanie zwraca 10 wyników, co daje 30 URL-i do scrapowania per rozdział. Claude ewaluuje zescrapowane treści w trybie surowym: akceptuje tylko artykuły naukowe, publikacje recenzowane, podręczniki akademickie, raporty badawcze i źródła z domen .edu. Blogi, strony marketingowe, fora, Wikipedia — odrzucone.

Jeśli po ewaluacji mniej niż 3 źródła polskojęzyczne przejdą filtr jakości, system automatycznie uruchamia fallback anglojęzyczny — generuje nowe zapytania w języku angielskim i powtarza cały cykl search-scrape-evaluate. To podwaja liczbę requestów do scrapera, ale znacząco poprawia jakość źródeł.

System referencji w Smart-Edu ma trzy poziomy. Poziom A to przypisy do dostarczonych źródeł — format `<sup>[N]</sup>`, gdzie N to numer z listy. Poziom B to referencje wyciągnięte z wnętrza źródeł — jeśli zescrapowany artykuł naukowy cytuje „Smith (2020)", system pozwala się na to powołać w formacie `<sup>[~Smith J., 2020]</sup>`. Poziom C to własne referencje Claude — format `<sup>[+Autor, Tytuł, Wydawnictwo, Rok]</sup>`, używane tylko gdy poziomy A i B nie pokrywają tematu. Na końcu system renumeruje wszystkie referencje do jednolitej numeracji i generuje sortowaną alfabetycznie bibliografię.

Kolejność pisania w Smart-Edu jest nieoczywista: wstęp jest pisany jako ostatni element. System najpierw generuje strukturę całej pracy, potem pisze rozdziały sekwencyjnie (każdy z kontekstem z poprzednich), potem zakończenie (z podsumowaniem wniosków z każdego rozdziału), a na końcu wstęp — bo dopiero wtedy wie, co praca rzeczywiście zawiera, i może napisać trafne cele badawcze, pytania i opis struktury.

Fragment system promptu dla prac akademickich — trzy poziomy przypisów:

```typescript
// backend/src/services/generation/writer.ts
// System prompt dla prac akademickich (fragment)

const footnoteInstructions = `
PRZYPISY — TRZY POZIOMY:
 
A) DOSTARCZONE ŹRÓDŁA (PRIORYTET 1):
   Format: <sup>[N]</sup> — numer ze zescrapowanej listy.
   MINIMUM 3-5 przypisów tego typu per rozdział.
 
B) REFERENCJE WYCIĄGNIĘTE ZE ŹRÓDEŁ (PRIORYTET 2):
   Jeśli w źródle [3] widzisz "Smith (2020) wykazał, że..."
   → powołaj się: <sup>[~Smith J., Digital Marketing, 2020]</sup>
 
C) WŁASNE PRZYPISY (PRIORYTET 3 — ostateczność):
   TYLKO gdy A i B nie pokrywają tematu.
   Format: <sup>[+Autor, Tytuł, Wydawnictwo, Rok]</sup>
   ZASADA: TYLKO prawdziwe, istniejące publikacje!
`;
```

## Dlaczego mikroserwis, nie biblioteka

Decyzja o wydzieleniu scrapera jako osobnego serwisu wynikała z trzech praktycznych problemów.

Problem pierwszy: Selenium z ChromeDriver zajmuje dużo RAM-u. Każda instancja Chrome to ~100 MB. Cztery instancje to 400 MB — za dużo, żeby trzymać to na każdej instancji EC2 obok aplikacji Node.js. Osobna maszyna dedykowana do scrapowania rozwiązuje problem zasobów.

Problem drugi: Selenium wymaga binary ChromeDriver i Google Chrome. Instalacja i aktualizacja tych zależności na każdym serwerze (trzy różne aplikacje, dwa regiony AWS) to koszmar utrzymaniowy. Centralny serwis na Elastic Beanstalk ma automatyczne zarządzanie środowiskiem.

Problem trzeci: rate limiting i kolejkowanie. Jeśli trzy aplikacje jednocześnie scrapują te same domeny, ryzyko zbanowania IP rośnie trzykrotnie. Centralny serwis z jednym IP jest łatwiejszy do monitorowania i zarządzania.

Minusy mikroserwisu: dodatkowa latencja (HTTP request zamiast wywołania funkcji), dodatkowy koszt ($20/mies. za t3.small), i single point of failure — gdy scraper padnie, wszystkie trzy aplikacje tracą zdolność web research. Fallbacki w każdej aplikacji łagodzą ten ostatni problem, ale nie eliminują go.

## Czego się nauczyłem

Detekcja SPA oparta na heurystyce działa w 95% przypadków. Pozostałe 5% to strony, które wyglądają jak SPA, ale nie są (fałszywe pozytywne — scraper niepotrzebnie uruchamia Selenium), albo strony, które są SPA, ale nie mają standardowych wskaźników (fałszywe negatywne — BeautifulSoup zwraca pusty tekst). Dla fałszywych negatywnych jedynym rozwiązaniem jest retry z Selenium po otrzymaniu pustego wyniku — czego obecna wersja nie implementuje.

Timeouty muszą być różne dla różnych klientów. MaturaPolski potrzebuje szybkiej odpowiedzi (uczeń czeka), więc timeout to 120 sekund. Smart-Copy może czekać dłużej (klient złożył zamówienie i dostanie email), więc timeout to 100–300 sekund. Smart-Edu generuje pracę godzinami, więc timeout nie jest krytyczny. Scraper sam ma timeout 600 sekund na Selenium — ale klient może się rozłączyć wcześniej.

Cztery ChromeDrivery to wystarczająco dużo dla mojej skali, ale nie dla peak load. Kiedy Smart-Edu generuje pracę magisterską (45 URL-i) jednocześnie z zamówieniem na Smart-Copy (15 URL-i), 60 requestów trafia do scrapera z czterema ChromeDriverami. Selenium obsługuje je sekwencyjnie, co wydłuża czas pipeline'u. Rozwiązanie: zwiększenie puli lub kolejkowanie requestów z priorytetami.

Google Custom Search API ma limit 100 darmowych zapytań dziennie. Przy trzech aplikacjach, z których każda generuje 1–3 zapytania per request, łatwo przekroczyć limit. Powyżej 100 zapytań Google nalicza $5 za 1000. W mojej skali to $5–10/miesiąc — akceptowalne, ale warto monitorować.
