---
title: "Jak zbudowałem multi-agent AI pipeline do generowania treści — kierownik, pisarze i 6 warstw kontroli jakości"
description: "Case study z budowy zaawansowanego systemu generowania treści AI w Smart-Copy.ai. Multi-agent architektura (kierownik + do 7 pisarzy), web research z Google + scraperem, automatyczne SEO, kontynuacja ucięć, walidacja zakończeń przez Claude i post-processing z linkami. Z prawdziwym kodem produkcyjnym."
pubDate: 2026-03-13
heroImage: "/images/blog/ai-pipeline-architecture.jpg"
heroImageAlt: "Schemat multi-agent pipeline do generowania treści AI"
category: "ai-copywriting"
tags:
  [
    "ai",
    "claude-api",
    "multi-agent",
    "pipeline",
    "generowanie-tresci",
    "typescript",
    "case-study",
    "smart-copy",
  ]
draft: false
author: "Karol Leszczyński"
pillar: false
relatedPosts: ["jeden-scraper-trzy-aplikacje-ai-mikroserwis"]
---

Większość narzędzi AI do generowania treści działa tak: użytkownik wpisuje temat, AI generuje tekst, użytkownik dostaje wynik. Jeden prompt, jedna odpowiedź. Dla bloga na 2 000 znaków to wystarczy. Dla artykułu na 50 000 znaków z SEO, linkami, tabelami i źródłami z internetu — nie.

Smart-Copy.ai to moja platforma do generowania treści copywriterskich, która obsługuje teksty od 1 000 do 300 000 znaków. Klient zamawia artykuł, podaje temat, wytyczne, opcjonalnie frazy SEO i linki — a system automatycznie przeszukuje internet, scrapuje źródła, planuje strukturę, generuje treść w częściach i waliduje wynik. Bez ludzkiej interwencji.

Ten artykuł opisuje architekturę tego systemu — z prawdziwym kodem produkcyjnym.

## Problem — dlaczego jeden prompt nie wystarczy

Claude (i każdy inny LLM) ma ograniczenia, które stają się krytyczne przy długich tekstach.

Po pierwsze, limit tokenów wyjściowych. Claude może wygenerować maksymalnie kilkanaście tysięcy tokenów w jednej odpowiedzi. Dla polskiego HTML to około 50 000–60 000 znaków. Ale klient zamówił 100 000 znaków — co teraz? Tekst zostaje ucięty w połowie zdania (`stop_reason: "max_tokens"`). Trzeba go kontynuować, ale tak, żeby kontynuacja była spójna z początkiem.

Po drugie, jakość spada z długością. Im dłuższy prompt i im więcej tekstu AI wygenerowało, tym bardziej „zapomina" o wytycznych z początku. Sekcja H2 numer 12 ignoruje frazy SEO, które były w prompcie. Rozwiązanie: podziel tekst na części, z każdą częścią powtórz kluczowe instrukcje.

Po trzecie, AI nie wie, co jest prawdą. Jeśli klient zamawia artykuł o „najnowszych trendach w SEO 2026", Claude odpowie na podstawie danych treningowych — potencjalnie nieaktualnych. Rozwiązanie: web research przed generowaniem, tak żeby AI pisało na podstawie świeżych źródeł.

## Architektura — 6 etapów pipeline'u

Każde zamówienie w Smart-Copy przechodzi przez sześć sekwencyjnych etapów. Każdy etap to osobny call do Claude API lub do zewnętrznego serwisu.

Etap 1: generowanie zapytania Google. Etap 2: wyszukiwanie w Google Custom Search API. Etap 3: scrapowanie wszystkich znalezionych źródeł. Etap 4: selekcja najlepszych źródeł przez Claude. Etap 5: generowanie treści (w jednym z trzech trybów, w zależności od długości). Etap 6: post-processing — walidacja zakończenia, uzupełnianie brakujących linków SEO, sprawdzanie kompletności.

Cały pipeline jest orkiestrowany przez jedną funkcję `processOrder()`, która iteruje po tekstach w zamówieniu i prowadzi każdy przez wszystkie etapy:

```typescript
// backend/src/services/textGenerationService.ts — processOrder() (skrócony)
export async function processOrder(orderId: string) {
  const order = await prisma.order.findUnique({
    where: { id: orderId },
    include: { texts: true },
  });

  for (const text of order.texts) {
    // Etap 1-2: Google query + search
    await updateTextProgress(text.id, "query");
    const googleQuery = await generateGoogleQuery(text);
    const searchResults = await searchGoogle(googleQuery, text.language);

    // Etap 3: Scrape ALL results (nie top 5 — wszystkie 15!)
    await updateTextProgress(text.id, "scraping-all");
    const allGoogleScraped = await scrapeUrls(
      searchResults.items.map((item) => item.link),
      false,
    );

    // Etap 4: Claude wybiera 3-8 najlepszych
    await updateTextProgress(text.id, "selecting");
    const selectedSources = await selectBestSourcesFromScraped(
      text,
      validScraped,
    );

    // Etap 5: Generowanie treści
    await updateTextProgress(text.id, "writing");
    await generateContent(text.id);

    await updateTextProgress(text.id, "completed");
  }
}
```

Status każdego etapu (`query`, `search`, `scraping-all`, `selecting`, `writing`, `completed`) jest zapisywany w bazie — frontend wyświetla go użytkownikowi jako animację postępu.

## Etap 1–2: Web research — AI nie pisze z pamięci

Pierwszym krokiem jest wygenerowanie zapytania do Google. Claude dostaje temat, rodzaj treści, język i wytyczne — i generuje krótkie zapytanie (5–7 słów). To celowo proste: Google działa lepiej z krótkimi frazami niż z rozbudowanymi zdaniami.

```typescript
// Etap 1: Claude generuje query
const prompt = `TEMAT: ${text.topic}
RODZAJ: ${text.textType}
WYTYCZNE: ${text.guidelines || "brak"}

ZASADY:
1. Zapytanie w języku: ${languageName.toUpperCase()}
2. Krótkie (5-7 słów)
3. TYLKO zapytanie, nic więcej

TWOJE ZAPYTANIE:`;

const message = await anthropic.messages.create({
  model: "claude-sonnet-4-6",
  max_tokens: 100,
  temperature: 0.3,
  messages: [{ role: "user", content: prompt }],
});
```

Drugie wywołanie to Google Custom Search API — zwraca do 15 wyników. Ważne: odpytuję dwie strony wyników (start=1 i start=11), żeby mieć wystarczającą puli źródeł.

## Etap 3: Scrapowanie — wszystko, nie tylko top 5

Kluczowa decyzja projektowa: scrapuję **wszystkie** wyniki z Google (10–15 URL-i), nie tylko te, które Claude wybrałby na podstawie snippetów. Dlaczego? Bo snippety Google (150 znaków) to za mało, żeby ocenić jakość źródła. Artykuł z doskonałym snippetem może mieć za paywallem 200 znaków tekstu. Artykuł z nudnym snippetem może zawierać 30 000 znaków merytorycznej treści.

Dlatego: najpierw scrapuj, potem oceniaj. Claude dostaje pełne treści (do 20 000 znaków per źródło) i wybiera na ich podstawie — nie na podstawie dwuzdaniowych snippetów.

Scraper to osobny mikroserwis (Python + Selenium), który automatycznie wykrywa strony SPA i przełącza się na headless Chrome. Timeout to 100 sekund dla źródeł Google, 300 sekund dla źródeł wskazanych przez użytkownika.

```typescript
// Etap 3: Scrapowanie z dynamicznym timeoutem
async function scrapeUrls(urls: string[], isUserSource: boolean = false) {
  const TIMEOUT = isUserSource ? 300000 : 100000; // 5 min vs 100s
  const MAX_TOTAL_LENGTH = isUserSource ? 200000 : 150000;

  for (const url of urls) {
    const response = await axios.post(
      `${SCRAPER_URL}/scrape`,
      { url },
      {
        timeout: TIMEOUT,
      },
    );

    // Inteligentny podział budżetu znaków
    const remainingSources = urls.length - i;
    const remainingSpace = MAX_TOTAL_LENGTH - currentTotalLength;
    const maxForThisSource = Math.floor(remainingSpace / remainingSources);

    scrapedText = sanitizeTextForDB(scrapedText);
    if (scrapedText.length > maxForThisSource) {
      scrapedText = scrapedText.substring(0, maxForThisSource);
    }
  }
}
```

Sanityzacja tekstu (`sanitizeTextForDB`) jest konieczna, bo zescrapowane strony mogą zawierać null bytes (`\x00`), których PostgreSQL nie akceptuje. Odkryłem to po tym, jak pipeline padł na zapytaniu do bazy z tajemniczym błędem „invalid byte sequence".

## Etap 4: Claude wybiera źródła — na podstawie treści, nie snippetów

Po scrapowaniu Claude dostaje fragmenty (do 20 000 znaków) każdego źródła i wybiera 3–8 najlepszych. To drugi call do Claude API w pipeline — osobny od generowania treści.

```typescript
// Etap 4: Selekcja na podstawie PEŁNEJ treści
async function selectBestSourcesFromScraped(text, scrapedResults) {
  const sourcePreviews = scrapedResults
    .map(
      (result, index) => `
    ŹRÓDŁO ${index + 1}:
    URL: ${result.url}
    Całkowita długość: ${result.length} znaków
    FRAGMENT (pierwsze 20,000 znaków):
    ${result.text.substring(0, 20000)}
  `,
    )
    .join("\n\n");

  const prompt = `Wybierz 3-8 NAJLEPSZYCH źródeł do napisania tekstu.
TEMAT: ${text.topic}
KRYTERIA: Merytoryczność, zgodność z tematem, aktualność.
IGNORUJ źródła z "403 Error", "SSL Error".

ZESCRAPOWANE ŹRÓDŁA:
${sourcePreviews}

Zwróć TYLKO numery oddzielone przecinkami:`;

  // Claude odpowiada np. "1,3,5,7"
}
```

Źródła użytkownika (URL-e i pliki PDF/DOCX podane przy zamówieniu) mają priorytet. Jeśli użytkownik dostarczył ponad 200 000 znaków materiałów — Google search jest w ogóle pomijany. System wykrywa to automatycznie:

```typescript
const USE_GOOGLE = userSourcesTotalLength < 200000;
if (!USE_GOOGLE) {
  console.log("Źródła użytkownika wystarczają — pomijam Google");
}
```

## Etap 5: Generowanie treści — trzy tryby w zależności od długości

To serce systemu. Smart-Copy używa trzech różnych strategii generowania w zależności od zamówionej długości tekstu.

**Tryb A: poniżej 10 000 znaków — jeden pisarz.** Claude dostaje temat, źródła, instrukcje SEO i pisze cały tekst w jednym callu. Prompt zawiera kalkulację struktury (ile sekcji H2, ile akapitów, ile słów na akapit), przykładowy akapit wzorcowy i twardy limit znaków.

**Tryb B: 10 000–50 000 znaków — kierownik + pisarz.** Najpierw Claude w roli „kierownika" generuje strukturę HTML (nagłówki H2, H3, opisy sekcji). Potem w roli „pisarza" wypełnia tę strukturę treścią. Dwa osobne calle API z różnymi promptami i temperaturami (kierownik: 0.5, pisarz: 0.7).

**Tryb C: powyżej 50 000 znaków — kierownik + wielu pisarzy.** Kierownik dzieli strukturę na części (do 7 pisarzy, po ~48 000 znaków każdy). Pisarze generują sekwencyjnie — każdy następny dostaje kontekst z poprzednich części (ostatnie 5 000 znaków) i listę już napisanych sekcji, żeby nie powtarzać treści.

```typescript
// Routing do odpowiedniego trybu
if (text.length < 10000) {
  finalContent = await generateShortContent(text, sources);
} else if (text.length < 50000) {
  const structureData = await generateStructure(text, 1); // 1 pisarz
  finalContent = await generateWithStructure(
    text,
    structureData.writerAssignments[0],
    sources,
  );
} else {
  const writersNeeded = Math.ceil(text.length / 48000);
  const maxWriters = Math.min(writersNeeded, 7);
  const structureData = await generateStructure(text, maxWriters);

  for (let i = 0; i < maxWriters; i++) {
    const part = await generateWithStructure(
      text,
      structureData.writerAssignments[i],
      sources,
      {
        number: i + 1,
        total: maxWriters,
        previousContent, // ostatnie 5000 znaków z poprzedniej części
        completedSections, // lista już napisanych sekcji
      },
    );
    parts.push(part);
  }
  finalContent = parts.join("\n\n");
}
```

Kluczowy detal: limit tokenów jest kalkulowany dynamicznie dla każdego tekstu. Polski HTML to około 4 znaki na token — więc dla tekstu 20 000 znaków ustawiam `max_tokens` na ~9 250 (z marginesem 85%):

```typescript
function calculateMaxTokens(targetLength: number): number {
  const baseTokens = Math.ceil(targetLength / 4);
  const withMargin = Math.ceil(baseTokens * 1.85);
  return Math.max(1000, Math.min(16000, withMargin));
}
```

Cap na 16 000 tokenów to celowa decyzja — większe wartości powodowały, że Claude generował tekst znacznie dłuższy niż zamówiony.

## Kontynuacja ucięć — kiedy Claude nie zmieści się w limicie

Przy długich tekstach Claude regularnie trafia w limit tokenów. Odpowiedź zostaje ucięta w połowie zdania (`stop_reason: "max_tokens"`). System wykrywa to i uruchamia pętlę kontynuacji.

Kontynuacja nie jest prostym „pisz dalej". System analizuje, które sekcje H2 ze struktury kierownika zostały już napisane, a które brakują — i instruuje Claude, żeby uzupełnił konkretne brakujące sekcje:

```typescript
async function continueFromTruncation(
  truncatedContent,
  text,
  sources,
  plannedStructure,
) {
  // Wyciągnij zaplanowane H2 ze struktury kierownika
  const plannedH2List =
    plannedStructure.match(/<h2[^>]*>([^<]*)<\/h2>/gi) || [];

  // Wyciągnij już napisane H2 z urwanego tekstu
  const writtenH2List = cleanContent.match(/<h2[^>]*>([^<]*)<\/h2>/gi) || [];

  // Znajdź brakujące sekcje
  const missingSections = plannedH2List.filter(
    (planned) =>
      !writtenH2List.some((written) =>
        written.toLowerCase().includes(planned.toLowerCase().substring(0, 20)),
      ),
  );

  // Prompt kontynuacji z konkretnymi instrukcjami
  const continuationPrompt = `KONTYNUUJ TEKST.
  BRAKUJĄCE SEKCJE (MUSISZ JE NAPISAĆ!):
  ${missingSections.join(", ")}
  
  OSTATNIE 3000 ZNAKÓW URWANEGO TEKSTU:
  ${lastContext}`;
}
```

Maksymalnie 3 próby kontynuacji per fragment. Jeśli po trzech próbach nadal brakuje sekcji — system loguje ostrzeżenie, ale nie blokuje pipeline'u.

## SEO — frazy kluczowe i linki wbudowane w prompt

Smart-Copy obsługuje dwa typy optymalizacji SEO: frazy kluczowe i linki z anchor textem.

Frazy kluczowe trafiają do promptu z instrukcją rozmieszczenia. Fraza główna musi pojawić się w H1 lub na początku pierwszego akapitu, a potem 2–4 razy naturalnie w tekście. Pozostałe frazy — równomiernie rozłożone.

Linki SEO są bardziej złożone. Klient podaje URL i anchor text (np. `{url: "https://agencja.pl", anchor: "agencja copywriterska z Torunia"}`). System oblicza ile linków zmieścić w tekście (2 dla krótkich, 5 dla długich) i generuje instrukcje z konkretnym przykładem wstawienia w kontekst tematu.

Po generowaniu system waliduje, czy wszystkie linki faktycznie pojawiły się w tekście:

```typescript
function validateSeoLinks(content, requiredLinks) {
  const missingLinks = [];
  for (const link of requiredLinks) {
    const urlEscaped = link.url.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const hrefRegex = new RegExp(
      `<a[^>]*href=["']${urlEscaped}["'][^>]*>`,
      "i",
    );

    if (!hrefRegex.test(content)) {
      missingLinks.push(link);
    }
  }
  return { valid: missingLinks.length === 0, missingLinks };
}
```

Jeśli brakuje linków — osobny call do Claude wstawia je naturalnie w istniejący tekst. Claude dostaje cały wygenerowany HTML i instrukcję „wstaw link X w środku akapitu Y, naturalnie gramatycznie".

## Post-processing — 6 warstw kontroli jakości

Po wygenerowaniu treści system przeprowadza serię walidacji i napraw.

**Warstwa 1: Weryfikacja zakończenia.** Claude analizuje ostatnie 1 500 znaków tekstu i sprawdza, czy ostatnie zdanie jest kompletne gramatycznie, czy nie jest urwane w połowie słowa, i czy tekst ma naturalne zakończenie (podsumowanie, CTA) a nie kończy się w środku sekcji merytorycznej.

```typescript
async function verifyAndFixEnding(
  content,
  contentLength,
  isLastPart,
  textTopic,
) {
  const validationPrompt = `Sprawdź czy ten fragment HTML kończy się 
  POPRAWNYM, KOMPLETNYM zdaniem polskim.
  
  SPRAWDŹ:
  1. Czy ostatnie zdanie jest gramatycznie poprawne?
  2. Czy nie jest urwane w połowie słowa?
  3. Czy ma NATURALNE ZAKOŃCZENIE ARTYKUŁU?`;

  // Claude odpowiada JSON: {isComplete, charsToRemove, hasConclusion}
}
```

**Warstwa 2: Generowanie brakującego zakończenia.** Jeśli `hasConclusion === false` — osobny call do Claude generuje 1–2 akapity podsumowujące.

**Warstwa 3: Pętla kompletności.** Do 5 prób kontynuacji, jeśli tekst jest niekompletny.

**Warstwa 4: Walidacja linków SEO.** Regex sprawdza, czy wszystkie zamówione linki są w tekście.

**Warstwa 5: Wstawianie brakujących linków.** Claude wstawia brakujące linki w naturalny kontekst.

**Warstwa 6: Sanityzacja bazy danych.** Usunięcie null bytes i znaków kontrolnych przed zapisem do PostgreSQL.

## Czego się nauczyłem budując ten pipeline

**Temperatura promptu ma znaczenie.** Kierownik (generujący strukturę) działa z temperaturą 0.5 — potrzebuję powtarzalności i logicznej struktury. Pisarz działa z temperaturą 0.7 — potrzebuję kreatywności i naturalnego języka. Ewaluator źródeł z 0.3 — precyzyjne decyzje binarne.

**Twardy limit tokenów wyjściowych jest konieczny.** Bez niego Claude generuje tekst 200% dłuższy niż zamówiony. Kalkuluję `max_tokens` na podstawie zamówionej długości: `targetLength / 4 * 1.85`, z capem na 16 000. Lepiej ucięty tekst (który kontynuuję) niż 50 000 znaków zamiast zamówionych 20 000.

**Każdy etap pipeline'u musi mieć fallback.** Scraper padł? Generuj bez źródeł. Claude nie wybrał źródeł? Weź 3 najdłuższe. Kontynuacja nie uzupełniła brakujących sekcji po 3 próbach? Zaloguj ostrzeżenie i idź dalej. Zapis do bazy się nie udał? Spróbuj bez zescrapowanych treści. Pipeline nie może się zatrzymać — klient zapłacił i czeka na email z gotowym tekstem.

**Prompt engineering to 80% roboty.** Kod pipeline'u (orchestracja, API calls, baza) to stosunkowo proste TypeScript. Prawdziwa praca to iterowanie promptów: jak powiedzieć Claude, żeby pisał dokładnie 20 000 znaków (nie 15 000, nie 30 000), żeby nie powtarzał sekcji w trybie multi-writer, żeby wstawiał linki SEO naturalnie w środek akapitu a nie na początek. Każda z tych instrukcji została wyciągnięta z dziesiątek nieudanych generacji.

**Logowanie jest ważniejsze niż myślisz.** Każdy prompt i każda odpowiedź Claude jest zapisywana w bazie (pola `queryPrompt`, `queryResponse`, `selectPrompt`, `selectResponse`, `structurePrompt`, `structureResponse`, `writerPrompts`, `writerResponses`). Kiedy klient zgłasza, że wygenerowany tekst jest za krótki albo nie ma linków SEO — mogę odtworzyć dokładnie co Claude dostał i co zwrócił. Bez tych logów debugging byłby niemożliwy.

## Kiedy ten model ma sens

Multi-agent pipeline z web research ma sens, kiedy generujesz teksty dłuższe niż 5 000 znaków, kiedy potrzebujesz aktualnych danych (nie polegasz na danych treningowych modelu), kiedy musisz kontrolować strukturę i format output (HTML, SEO), i kiedy pipeline działa bez nadzoru (klient zamówił i czeka — nie ma człowieka, który by sprawdzał wynik).

Nie ma sensu, kiedy generujesz krótkie teksty (tweet, nagłówek, opis produktu) — jeden prompt wystarczy. Nie ma sensu, kiedy koszt API jest problemem — pipeline z 6–10 callami do Claude per tekst kosztuje kilkanaście razy więcej niż jeden call. I nie ma sensu, kiedy masz czas na ręczną edycję — ludzki redaktor nadal jest lepszy od 6 warstw post-processingu.

Mój pipeline to kompromis: zamieniam koszt ludzkiej pracy na koszt API, żeby dostarczyć klientowi gotowy tekst w 3–10 minut zamiast 3–10 godzin. Przy artykule za 50 zł i koszcie API na poziomie 2–5 zł — ten kompromis się opłaca.
