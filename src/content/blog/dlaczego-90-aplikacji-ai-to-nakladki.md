---
title: "Dlaczego 90% aplikacji AI to nakładki na API — i czemu to nie wystarczy"
description: "Większość 'narzędzi AI' to formularz, jeden request do Claude/GPT i wyświetlenie odpowiedzi. Działa dla pytań o stolicę Francji. Nie działa dla niczego, co wymaga aktualnych danych, kontroli jakości i powtarzalności. Artykuł o tym, dlaczego surowa wiedza modelu to za mało — i jak budować systemy, które używają AI jako jednego z narzędzi, nie jako całego produktu."
pubDate: 2026-03-13
heroImage: "/images/blog/ai-wrapper-vs-system.jpg"
heroImageAlt: "Porównanie prostej nakładki na API AI z rozbudowanym systemem wykorzystującym AI"
category: "ai-copywriting"
tags:
  [
    "ai",
    "llm",
    "architektura",
    "web-research",
    "multi-agent",
    "quality-control",
    "opinia",
  ]
draft: false
author: "Karol Leszczyński"
pillar: true
relatedPosts:
  [
    "multi-agent-ai-pipeline-generowanie-tresci",
    "jeden-scraper-trzy-aplikacje-ai-mikroserwis",
  ]
---

Otwórz dowolny katalog narzędzi AI — Product Hunt, AlternativeTo, listy „Top 100 AI Tools". Większość z nich działa tak samo: formularz, w który wpisujesz temat. Request do API Claude lub GPT. Wyświetlenie odpowiedzi. Czasem z ładnym CSS.

To nie jest aplikacja AI. To nakładka na cudze API z marginem.

Nie mówię tego z pozycji teoretyka. Buduję aplikacje, które używają Claude API w produkcji od ponad roku — generator treści copywriterskich, platformę do nauki matury z AI, generator prac akademickich. Na początku też budowałem nakładki. Szybko się okazało, że nie działają. Nie dlatego, że model jest zły. Dlatego, że model sam nie wystarczy.

## Problem numer jeden — model nie wie, co się dzieje dzisiaj

Każdy model językowy ma datę odcięcia wiedzy. Claude wie, co było w internecie do pewnego momentu. Nie wie, co zmieniło się wczoraj. Nie wie, że firma X zbankrutowała, że ustawa Y weszła w życie, że technologia Z została uznana za przestarzałą.

Kiedy klient zamawia artykuł „Najnowsze trendy w SEO na 2026 rok", model odpowie — ale na podstawie danych treningowych. Może wymienić trendy z 2024 roku jako „najnowsze". Może polecić narzędzie, które już nie istnieje. Może pominąć zmianę w algorytmie Google, która wydarzyła się trzy miesiące temu.

Proste nakładki na API ignorują ten problem. Wysyłają prompt „napisz artykuł o trendach SEO 2026" i wyświetlają odpowiedź. Użytkownik nie wie, że czyta potencjalnie nieaktualne informacje, bo tekst brzmi pewnie i autorytatywnie — tak jak każdy tekst wygenerowany przez LLM.

Rozwiązanie nie jest skomplikowane koncepcyjnie, ale wymaga infrastruktury. Przed generowaniem treści system musi przeszukać internet, pobrać aktualne źródła i dać je modelowi jako kontekst. Model pisze na podstawie dostarczonych materiałów, nie na podstawie swojej pamięci.

W moich aplikacjach wygląda to tak: Claude generuje zapytanie do Google (5–7 słów kluczowych), Google Custom Search zwraca 10–15 wyników, dedykowany scraper pobiera pełną treść każdej strony, Claude analizuje zescrapowane źródła i wybiera 3–8 najlepszych, a dopiero potem generuje tekst — bazując na świeżych materiałach.

```typescript
// Scraper z automatycznym wykrywaniem stron SPA (React, Next.js)
const TIMEOUT = isUserSource ? 300000 : 100000; // 5 min vs 100s
const response = await axios.post(
  `${SCRAPER_URL}/scrape`,
  { url },
  {
    timeout: TIMEOUT,
  },
);
// Sanityzacja — PostgreSQL nie akceptuje null bytes ze zescrapowanych stron
scrapedText = sanitizeTextForDB(scrapedText);
```

Centralny scraper (Python + Selenium na osobnej instancji EC2) automatycznie wykrywa strony SPA i przełącza się na headless Chrome. Bez tego połowa stron zwracałaby pusty HTML — bo treść renderuje się w JavaScript, a prosty `fetch()` tego nie widzi.

Cztery instancje ChromeDriver działają równolegle, bo przy generowaniu jednego artykułu system scrapuje 15 URL-i. Przy pracy akademickiej — 45. Bez równoległości pipeline trwałby godziny.

## Problem numer dwa — model nie kontroluje swojej długości

Powiedz Claude: „napisz artykuł na 20 000 znaków". Dostaniesz coś między 8 000 a 35 000. Może bliżej 20 000, może nie. Powiedz „napisz artykuł na 100 000 znaków" — i model wygeneruje 40 000, bo trafi w limit tokenów wyjściowych i tekst zostanie ucięty w połowie zdania.

To fundamentalny problem dla każdego produktu, w którym klient płaci za określoną długość tekstu. Nakładka na API nie ma na to odpowiedzi — wyświetla to, co model zwrócił, i modli się, żeby było odpowiedniej długości.

System, który traktuje AI jako narzędzie (a nie jako cały produkt), rozwiązuje to na kilku poziomach.

Na poziomie promptu: kalkuluję strukturę tekstu przed generowaniem — ile sekcji H2, ile akapitów, ile słów na akapit — i daję modelowi konkretne cele liczbowe zamiast ogólnego „napisz 20 000 znaków". Dla tekstu 20 000 znaków to 3 080 słów, 31 akapitów, 8 sekcji H2. Model dostaje tabelę z rozkładem, nie abstrakcyjną liczbę.

Na poziomie limitu tokenów: dynamicznie obliczam `max_tokens` na podstawie zamówionej długości. Polski HTML to około 4 znaki na token. Dla 20 000 znaków ustawiam limit na ~9 250 tokenów. Bez tego model generuje tekst 200% dłuższy niż zamówiony, bo nie ma powodu się zatrzymać.

Na poziomie kontynuacji: jeśli tekst zostaje ucięty (`stop_reason: "max_tokens"`), system automatycznie analizuje, które sekcje ze struktury zostały już napisane, a które brakują — i uruchamia kontynuację z precyzyjnymi instrukcjami:

```typescript
// System porównuje zaplanowane H2 z napisanymi
const missingSections = plannedH2List.filter(
  (planned) =>
    !writtenH2List.some((written) =>
      written.toLowerCase().includes(planned.toLowerCase().substring(0, 20)),
    ),
);
// I instruuje Claude: "napisz brakujące sekcje: X, Y, Z"
```

Na poziomie walidacji: po wygenerowaniu Claude w osobnym callu analizuje ostatnie 1 500 znaków i sprawdza, czy tekst kończy się pełnym zdaniem i ma naturalne zakończenie. Jeśli nie — system generuje podsumowanie lub kontynuuje.

To cztery warstwy kontroli jednego parametru — długości. Nakładka na API ma zero warstw.

## Problem numer trzy — model nie jest powtarzalny

Ten sam prompt wysłany dwa razy daje dwa różne wyniki. Dla chatbota to zaleta — konwersacja jest naturalna. Dla produktu SaaS to wada — klient oczekuje, że artykuł na 20 000 znaków będzie miał 20 000 znaków, że będzie miał sekcje H2, listy, tabele, i że linki SEO znajdą się w środku akapitów a nie na początku.

Nakładka na API mówi „AI jest nieprzewidywalne, sorry". System z kontrolą jakości mówi „zwalidujmy wynik i naprawmy, co trzeba".

W mojej aplikacji po wygenerowaniu tekstu system wykonuje serię automatycznych sprawdzeń. Czy wszystkie zamówione linki SEO są w tekście? Regex sprawdza każdy URL — jeśli brakuje, osobny call do Claude wstawia brakujący link naturalnie w kontekst. Czy tekst ma zakończenie? Claude analizuje ostatni fragment — jeśli tekst urywa się w środku sekcji merytorycznej bez podsumowania, system generuje zakończenie. Czy tekst jest kompletny? Do pięciu prób kontynuacji, jeśli walidacja wykryje niekompletność.

```typescript
// Post-processing: 6 warstw kontroli jakości
// Warstwa 1: Weryfikacja zakończenia przez Claude
const endingValidation = await verifyAndFixEnding(
  finalContent,
  text.length,
  true,
  text.topic,
);

// Warstwa 2: Generowanie brakującego zakończenia
if (endingValidation.needsConclusion) {
  finalContent = await addConclusion(endingValidation.fixed, text);
}

// Warstwa 3-4: Walidacja i uzupełnienie linków SEO
const linkValidation = validateSeoLinks(finalContent, seoLinks);
if (!linkValidation.valid) {
  finalContent = await addMissingSeoLinks(
    finalContent,
    linkValidation.missingLinks,
  );
}
```

Każda z tych warstw to osobna logika, osobny kod, często osobny call do API. Razem zajmują więcej linii kodu niż samo generowanie treści.

## Problem numer cztery — model robi wszystko „okej", ale nic „dobrze"

Poproś Claude o napisanie artykułu 50 000 znaków w jednym prompcie. Dostaniesz artykuł. Będzie poprawny gramatycznie. Będzie miał strukturę. Ale sekcja numer 10 będzie powtarzać myśli z sekcji numer 3. Styl będzie się zmieniać — początek formalny, środek coraz luźniejszy. Frazy SEO, które model miał rozłożyć równomiernie, skupią się w pierwszych 5 000 znaków (bo tam prompt był „świeży" w kontekście).

To problem uwagi (attention) — im dłuższy kontekst, tym mniej uwagi model poświęca instrukcjom z początku promptu. Przy 100 000 tokenów kontekstu, instrukcje z pozycji 1–100 mają statystycznie mniejszy wpływ niż przy kontekście 10 000 tokenów.

Rozwiązanie: nie każ modelowi robić wszystkiego naraz. Podziel pracę na role.

W mojej aplikacji dla tekstów powyżej 10 000 znaków Claude pracuje w dwóch rolach. Najpierw jako „kierownik" — z temperaturą 0.5 (precyzja, logika) generuje strukturę: nagłówki H2, H3, opisy sekcji, rozmieszczenie list i tabel. Potem jako „pisarz" — z temperaturą 0.7 (kreatywność, naturalność) wypełnia tę strukturę treścią, sekcja po sekcji.

Dla tekstów powyżej 50 000 znaków kierownik dzieli strukturę na części i przydziela je do pisarzy (do 7 równoległych). Każdy pisarz generuje swoją część sekwencyjnie, dostając kontekst z poprzednich części i listę już napisanych sekcji — żeby nie powtarzać treści.

```typescript
// 3 tryby generowania — w zależności od długości
if (text.length < 10000) {
  // Jeden pisarz — prosty prompt
  finalContent = await generateShortContent(text, sources);
} else if (text.length < 50000) {
  // Kierownik (temp 0.5) + Pisarz (temp 0.7)
  const structureData = await generateStructure(text, 1);
  finalContent = await generateWithStructure(
    text,
    structureData.writerAssignments[0],
    sources,
  );
} else {
  // Kierownik + do 7 pisarzy sekwencyjnie
  const maxWriters = Math.min(Math.ceil(text.length / 48000), 7);
  const structureData = await generateStructure(text, maxWriters);
  // Każdy pisarz dostaje completedSections i previousContent
}
```

To nie jest rocket science. To wzorzec „divide and conquer" zastosowany do generowania tekstu. Ale wymaga kodu, który nakładka na API nie ma.

## Kiedy nakładka wystarczy, a kiedy nie

Nakładka na API jest wystarczająca, kiedy generujesz krótkie teksty (poniżej 2 000 znaków), kiedy nie potrzebujesz aktualnych danych (definicje, tłumaczenia, brainstorming), kiedy tolerujesz zmienność jakości (narzędzie wewnętrzne, brudnopis), i kiedy nie masz wymagań formatowania (czysty tekst, nie HTML z SEO).

Nakładka nie wystarczy, kiedy klient płaci za określony wynik (długość, format, elementy), kiedy tekst musi bazować na aktualnych źródłach (nie na wiedzy treningowej), kiedy potrzebujesz powtarzalności (każdy tekst musi mieć linki SEO, tabele, listy), i kiedy generujesz cokolwiek powyżej 10 000 znaków.

Różnica między nakładką a systemem to nie ilość kodu. To filozofia: czy AI jest produktem, czy narzędziem. Nakładka mówi „AI napisze tekst". System mówi „AI napisze tekst, ale najpierw znajdę mu aktualne źródła, potem sprawdzę, czy napisał to co miał, a na końcu naprawię to, co pominął". Jedno zdanie vs pipeline z sześcioma etapami i sześcioma warstwami kontroli jakości.

Budowanie systemu jest droższe — więcej kodu, więcej callów API, więcej infrastruktury (scraper, baza do logów, walidatory). Ale to jedyna droga do produktu, za który klient zapłaci więcej niż $5/miesiąc. Bo za $5/miesiąc może sam otworzyć claude.ai i wpisać prompt.
