---
title: "AI w aplikacjach — kiedy to overkill, a kiedy jedyne sensowne rozwiązanie"
description: "Nie każdy problem wymaga AI. Allegro sync, cron rebuildy, walidacja formularzy — to robota dla skryptu, nie dla modelu za $0.003/request. Ale ocena wypracowań, selekcja źródeł internetowych, generowanie 2000 unikalnych opisów produktów? Tutaj skrypt się poddaje. Artykuł o granicy między skryptem a AI — z kodem produkcyjnym z trzech różnych aplikacji."
pubDate: 2026-03-13
heroImage: "/images/blog/ai-vs-script-decision.jpg"
heroImageAlt: "Schemat decyzyjny — kiedy AI, kiedy skrypt"
category: "ai-copywriting"
tags:
  [
    "ai",
    "architektura",
    "automatyzacja",
    "claude-api",
    "e-commerce",
    "edtech",
    "case-study",
  ]
draft: false
author: "Karol Leszczyński"
pillar: true
relatedPosts:
  [
    "dlaczego-90-aplikacji-ai-to-nakladki",
    "multi-agent-ai-pipeline-do-generowania-tresci",
  ]
---

Prowadzę sklep e-commerce z silnikami elektrycznymi, platformę do nauki przed maturą z polskiego i generator treści copywriterskich. Trzy różne produkty, trzy różne grupy użytkowników. W każdym z nich używam Claude API. W żadnym z nich AI nie jest jedynym narzędziem — i w żadnym nie jest widoczne na pierwszy rzut oka.

Ten artykuł nie jest o tym, jak „wdrożyć AI w biznesie". Jest o konkretnej decyzji inżynierskiej, którą podejmuję kilka razy w tygodniu: czy ten problem rozwiązać skryptem, czy modelem językowym. Odpowiedź zależy od jednej zmiennej — przewidywalności inputu.

## Zasada numer jeden — jeśli da się to zrobić skryptem, zrób to skryptem

W moim sklepie silniki-elektryczne.com.pl mam bidirectional sync z Allegro. Kiedy klient kupuje silnik w sklepie, stock spada. Kiedy stock spada, Allegro musi się dowiedzieć. Kiedy stock spada do zera, oferta na Allegro musi zostać zakończona. Kiedy klient anuluje zamówienie i stock wraca — oferta musi zostać reaktywowana, system musi odczekać 1,5 sekundy (bo Allegro potrzebuje czasu na przetworzenie), a dopiero potem ustawić nowy stan magazynowy.

To jest złożone, ale całkowicie deterministyczne. Input jest przewidywalny: stock zmienił się z X na Y. Output jest jednoznaczny: wyślij request do Allegro API z nowym stanem. Nie ma tu pola interpretacyjnego. Nie ma sytuacji, w której dwa rozsądne podejścia dadzą różne wyniki. AI w tym miejscu to wyrzucanie pieniędzy — każdy request do Claude kosztuje, a zwróci dokładnie to samo, co pięć linii TypeScript z `if/else`.

To samo dotyczy: automatycznych rebuildów stron satelickich (CodeBuild co 30 minut — cron, nie AI), walidacji formularzy (regex i Zod, nie model językowy), synchronizacji cen między sklepem a Allegro (mapping 1:1), generowania feedów XML dla Google Merchant (template + dane z bazy), wysyłki emaili transakcyjnych (SES + template, nie Claude piszący „Twoje zamówienie zostało wysłane").

Kuszące jest użycie AI do wszystkiego — ale każdy call do API to koszt, latencja i niedeterminizm. Jeśli problem jest strukturalny i powtarzalny — skrypt jest szybszy, tańszy i bardziej przewidywalny.

## Kiedy skrypt się poddaje — trzy scenariusze z produkcji

Są problemy, w których input jest za szeroki, za nieprzewidywalny, za „ludzki", żeby skrypt sobie poradził. W moich aplikacjach mam trzy takie scenariusze — od najprostszego do najbardziej złożonego.

### Scenariusz 1: Generowanie opisów produktów (sklep e-commerce)

W sklepie mam ponad 2 000 silników elektrycznych. Każdy potrzebuje unikalnego opisu — dla SEO, dla klienta, dla Google Merchant. Ręcznie? Przy 15 minut na opis to 500 godzin pracy. Przy 2 opisach dziennie — ponad dwa lata.

Template nie wystarczy, bo silniki różnią się zastosowaniami. Silnik 0.55 kW idzie do wentylacji. Silnik 7.5 kW idzie do pras i kompresów. Silnik z hamulcem ma inne zalety niż silnik z chłodzeniem obcym. Template wygenerowałby „Silnik elektryczny o mocy X kW i obrotach Y obr/min" — i tyle. Dla 2 000 produktów z tym samym zdaniem Google obniży ranking za duplicate content.

Moje rozwiązanie: przycisk „Generuj opis AI" w panelu admina. Jedno kliknięcie, 3–5 sekund, unikalny opis w HTML:

```typescript
// backend/src/routes/admin-products.ts — endpoint /generate-description
app.post("/generate-description", async (request, reply) => {
  const { productId } = request.body;
  const product = await prisma.product.findUnique({
    where: { id: productId },
  });

  const power = (product.power as any)?.value || "?";
  const rpm = (product.rpm as any)?.value || "?";

  const prompt = `Napisz profesjonalny, SEO-friendly opis produktu
dla sklepu z silnikami elektrycznymi.

Produkt: ${product.name}
Producent: ${product.manufacturer}
Moc: ${power} kW
Obroty: ${rpm} obr/min
Stan: ${product.condition === "nowy" ? "Nowy" : "Używany"}
Wielkość mechaniczna: ${product.mechanicalSize}
Średnica wału: ${product.shaftDiameter} mm
${product.weight ? `Waga: ${product.weight} kg` : ""}

Napisz 3-4 akapity. Używaj tagów <h2> i <p>.
Skup się na: zastosowaniach, zaletach, parametrach.`;

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-sonnet-4-6",
      max_tokens: 1024,
      messages: [{ role: "user", content: prompt }],
    }),
  });

  const result = await res.json();
  const text = result.content?.[0]?.text || "";
  return { success: true, data: { description: text } };
});
```

To najprostszy możliwy przypadek użycia AI w aplikacji. Jeden prompt, jedna odpowiedź, zero post-processingu. Ale działa, bo rozwiązuje realny problem — 2 000 unikalnych opisów zamiast szablonowych kopii. Koszt per opis: około $0.005 (Claude Sonnet). Koszt 2 000 opisów: $10. Alternatywa — copywriter za 20 zł/opis — to 40 000 zł.

Zauważ: użytkownik końcowy (klient sklepu) nie wie, że opis wygenerował AI. Widzi profesjonalny tekst o parametrach silnika. Admin sklepu klika przycisk i dostaje gotowy HTML. AI jest narzędziem wewnętrznym, nie feature'em marketingowym.

### Scenariusz 2: Selekcja i ocena źródeł internetowych (Smart-Copy)

Smart-Copy to mój generator treści copywriterskich. Klient zamawia artykuł, system przeszukuje internet, scrapuje źródła i generuje tekst. Ale między „przeszukaj internet" a „napisz artykuł" jest krok, którego skrypt nie ogarnie — ocena jakości źródeł.

Google zwraca 15 wyników. Mój scraper pobiera pełną treść każdej strony. Mam 15 tekstów, łącznie 200 000 znaków. Które z nich są wartościowe? Które zawierają spam, reklamy, treści nieaktualne? Które mają dane, a które ogólniki?

Skrypt mógłby filtrować po długości (odrzuć strony poniżej 500 znaków), po błędach HTTP (odrzuć 403, SSL Error), po słowach kluczowych. Ale nie oceni, czy artykuł o SEO z 2024 roku jest nadal aktualny. Nie oceni, czy tekst akademicki jest bardziej wartościowy niż blog post z tym samym tematem. Nie oceni, czy źródło pokrywa temat klienta, czy tylko go tangencjalnie dotyka.

Claude dostaje 20 000 znaków z każdego źródła i wybiera 3–8 najlepszych:

```typescript
// backend/src/services/textGenerationService.ts — selekcja źródeł
async function selectBestSourcesFromScraped(text, scrapedResults) {
  const sourcePreviews = scrapedResults
    .map(
      (result, index) => `
    ŹRÓDŁO ${index + 1}:
    URL: ${result.url}
    Długość: ${result.length} znaków
    FRAGMENT:
    ${result.text.substring(0, 20000)}
  `,
    )
    .join("\n\n");

  const message = await anthropic.messages.create({
    model: "claude-sonnet-4-6",
    max_tokens: 150,
    temperature: 0.3, // niska — chcę precyzji, nie kreatywności
    messages: [
      {
        role: "user",
        content: `Wybierz 3-8 NAJLEPSZYCH źródeł.
        TEMAT: ${text.topic}
        KRYTERIA: Merytoryczność, zgodność, aktualność.
        IGNORUJ źródła z błędami.
        
        ${sourcePreviews}
        
        Zwróć TYLKO numery oddzielone przecinkami:`,
      },
    ],
  });
  // Claude odpowiada np. "1,3,5,7" — parsujemy na indeksy
}
```

Temperatura 0.3 — bo to nie jest zadanie kreatywne. To ocena, klasyfikacja, selekcja. Chcę powtarzalności. Chcę, żeby przy tym samym zestawie źródeł Claude wybrał te same artykuły. Gdybym ustawił temperaturę 0.9, przy każdym wywołaniu dostawałbym inny zestaw — a to oznacza niespójną jakość wynikowego tekstu.

To jest scenariusz, w którym AI działa „w tle". Klient Smart-Copy nie wie, że Claude ocenił 15 źródeł i wybrał 5. Widzi gotowy artykuł. Ale jakość tego artykułu jest bezpośrednio zależna od jakości selekcji — AI na etapie, którego nikt nie widzi.

### Scenariusz 3: Ocena wypracowań maturalnych (MaturaPolski)

To mój najbardziej zaawansowany przypadek — i jednocześnie ten, gdzie AI jest absolutnie niezastępowalne.

MaturaPolski.pl to platforma do nauki przed maturą z polskiego. Uczeń pisze wypracowanie na temat „Czy Raskolnikow zasłużył na odkupienie?". System musi ocenić ten tekst na kilku kryteriach: zgodność z tematem, argumentacja, znajomość lektury, poprawność językowa, kompozycja. I dać konkretny feedback — co jest dobrze, co poprawić, gdzie brakuje odwołań do tekstu.

Dlaczego skrypt tu nie wystarczy? Bo każdy uczeń pisze inaczej. Jeden zaczyna od cytatu z Dostojewskiego. Drugi od kontekstu filozoficznego. Trzeci od porównania z Antygone. Czwarty pisze slangiem. Piąty pisze pięknie, ale nie na temat.

Regex nie oceni, czy argument „Raskolnikow żałował, bo płakał" jest merytoryczny. Keyword matching nie rozpozna, czy uczeń odwołał się do sceny z siekierą albo do epilogu. Analiza sentymentu nie powie, czy kompozycja jest spójna.

AI tutaj nie jest opcją — jest jedynym narzędziem, które potrafi przeczytać tekst napisany przez człowieka i dać feedback zbliżony do tego, jaki dałby nauczyciel. Nie identyczny — ale wystarczająco dobry, żeby uczeń wiedział, nad czym pracować. A nauczyciel kosztuje 100 zł/h i nie jest dostępny o 23:00, kiedy uczeń skończy pisać wypracowanie przed jutrzejszą maturą.

W tym scenariuszu AI jest widoczne dla użytkownika — uczeń wie, że jego tekst ocenia AI. Ale technologia pod spodem jest znacznie głębsza, niż widzi. System nie wysyła surowego wypracowania do Claude z pytaniem „oceń". Najpierw przeszukuje internet (Google Custom Search) po temacie i lekturze, scrapuje aktualne opracowania, podaje je Claude jako kontekst — żeby ocena bazowała na rzeczywistej wiedzy o lekturze, a nie tylko na tym, co model „pamięta" z treningu.

## Ile to kosztuje — prawdziwe liczby

Koszt API to główny argument przeciwko używaniu AI tam, gdzie nie trzeba. Oto moje realne koszty z produkcji.

Generowanie opisu produktu (Stojan): jeden call, Claude Sonnet, ~500 tokenów input + ~400 tokenów output. Koszt: ~$0.005 per opis. Przy 50 opisach miesięcznie: $0.25.

Selekcja źródeł (Smart-Copy): jeden call, ~15 000 tokenów input (źródła) + 20 tokenów output (numery). Koszt: ~$0.05 per selekcja. Przy 100 zamówieniach miesięcznie: $5.

Ocena wypracowania (MaturaPolski): web research (1 call na query + 1 na selekcję) + ocena (1 call, ~4 000 tokenów). Koszt: ~$0.08 per ocena. Przy 500 ocenach miesięcznie: $40.

Cały pipeline Smart-Copy (research + selekcja + generowanie + post-processing): 4–8 callów Claude per tekst. Koszt: $0.20–$0.80 per tekst, w zależności od długości. Przy 100 zamówieniach: $20–$80.

Suma: $65–$125 miesięcznie na API Claude, na trzy aplikacje produkcyjne. To mniej niż koszt jednej instancji EC2.

Dla porównania: gdybym użył AI do Allegro sync (zamiast skryptu), to przy 200 synchronizacjach dziennie × $0.003 per call × 30 dni = $18/miesiąc. Za coś, co deterministyczny skrypt robi za $0, szybciej i bez ryzyka halucynacji.

## Reguła decyzyjna — kiedy AI, kiedy skrypt

Po roku budowania aplikacji z AI wykrystalizował mi się prosty test. Trzy pytania, które zadaję sobie przed każdą decyzją architektoniczną.

Pierwsze pytanie: czy input jest przewidywalny? Jeśli tak — skrypt. Zmiana stocku z 5 na 4 to przewidywalny input. Wypracowanie napisane przez maturzystę — nieprzewidywalny.

Drugie pytanie: czy istnieje jedna „prawidłowa" odpowiedź? Jeśli tak — skrypt. Stock na Allegro powinien wynosić 4, nie „około 4". Ale ocena wypracowania na skali 1–5? Dwóch nauczycieli może dać różne noty i obaj mogą mieć rację.

Trzecie pytanie: czy koszt błędu jest akceptowalny? AI halucynuje. Rzadko, ale halucynuje. Jeśli halucynacja w opisie produktu oznacza „silnik 5.5 kW opisany jako 7.5 kW" — admin to złapie przy przeglądzie. Jeśli halucynacja w Allegro sync oznacza „stock ustawiony na 999 zamiast 0" — klienci zamawiają produkty, których nie ma. Pierwszy przypadek jest akceptowalny. Drugi nie.

Jeśli na wszystkie trzy pytania odpowiedź brzmi „nie" — AI. Jeśli na którekolwiek „tak" — zastanów się dwa razy.

## AI niewidoczne dla użytkownika — i to jest najciekawsze

Większość dyskusji o AI w aplikacjach koncentruje się na chatbotach, generatorach treści, asystentach — czyli na AI jako feature widocznym dla użytkownika. „Nasz produkt ma AI!" jako bullet point na landing page.

W moich aplikacjach najcenniejsze zastosowania AI są niewidoczne. Klient sklepu nie wie, że opis silnika wygenerował Claude. Użytkownik Smart-Copy nie wie, że Claude wybrał 5 z 15 źródeł. Admin sklepu nie wie, że przycisk „Generuj opis" to jeden call do API z promptem, który iterowałem przez kilka tygodni.

To jest dojrzałe zastosowanie AI — jako warstwa logiki, nie jako marketing. Tak jak nikt nie chwali się, że „nasz sklep używa PostgreSQL" (bo to narzędzie, nie feature), tak AI w dojrzałych aplikacjach powinno być narzędziem, które rozwiązuje konkretny problem. Nie feature'em, który sprzedaje.

Kiedy patrzę na swoje trzy aplikacje, widzę wzorzec. Kod biznesowy (routes, CRUD, auth, Stripe, Allegro sync) to 80% codebase. AI to 20% — ale te 20% rozwiązuje problemy, których pozostałe 80% nie jest w stanie ruszyć. I odwrotnie: te 80% deterministycznego kodu zapewnia, że AI działa w kontrolowanym środowisku — z walidacją, fallbackami, logowaniem i retry logic.

AI nie jest produktem. AI jest śrubokrętem. Bardzo drogim, bardzo inteligentnym śrubokrętem — ale nadal śrubokrętem. A dobry inżynier nie dokręca śrub młotkiem tylko dlatego, że młotek jest bardziej imponujący.
