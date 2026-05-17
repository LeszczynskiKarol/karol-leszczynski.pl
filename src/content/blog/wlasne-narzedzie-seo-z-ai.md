---
title: "Własne narzędzie do analityki SEO z AI — jak zbudowałem panel do zarządzania 23 domenami, którego nie zastąpi żaden gotowy tool"
description: "Case study z budowy SEO Command Center: Fastify + Prisma + React + Claude AI. Integracja z Google Search Console, automatyczny link crawl, timeline pozycji, AI Link Builder z commitami na GitHub i auto-deploy. Wszystko na własnej infrastrukturze AWS."
pubDate: 2026-03-28
heroImage: "/images/blog/seo-command-center-dashboard.jpg"
heroImageAlt: "Dashboard SEO Command Center z ciemnym motywem Bloomberg terminal"
category: "seo-techniczne"
tags:
  [
    "seo",
    "analityka",
    "google search console",
    "ai",
    "claude",
    "fastify",
    "react",
    "typescript",
    "aws",
    "case study",
  ]
draft: false
author: "Karol Leszczyński"
pillar: true
relatedPosts: ["synchronizacja-allegro-sklep"]
---

Mam 23 domeny. Sklep e-commerce z silnikami elektrycznymi, platforma SaaS do generowania prac akademickich, serwis do nauki na maturę z polskiego, sieć stron zapleczowych o copywritingu, satelity SEO wspierające linkowanie. Każda na AWS — Astro SSG na S3 + CloudFront, aplikacje na EC2 z Fastify i PostgreSQL. Każda z własnym sitemapem, profilem w Google Search Console, strukturą linków wewnętrznych i zewnętrznych.

Przez lata zarządzałem tym chaosem przez Google Search Console. Dwadzieścia trzy zakładki w przeglądarce. Każda domena osobno. Klikasz domenę, sprawdzasz pozycje, przechodzisz do następnej. Chcesz porównać jak fraza rankuje na dwóch domenach — otwierasz dwa raporty i ręcznie zestawiasz. Chcesz zobaczyć jakie linki prowadzą między Twoimi domenami — nie ma takiej opcji w GSC.

W pewnym momencie doszedłem do ściany.

<!-- SCREEN: Google Search Console z wieloma domenami — pokazać, jak wygląda zarządzanie 23 domenami w GSC (lista domen w sidebarze) -->

## Dlaczego Google Search Console przestał wystarczać

GSC jest narzędziem do monitorowania jednej domeny na raz. Przy 23 domenach to nie narzędzie — to tortura. Problemy, które mnie dobiły:

Brak widoku zbiorczego. Ile mam łącznie kliknięć ze wszystkich domen? Jaki procent stron jest zaindeksowany? Ile mam złamanych linków? W GSC — otwórz każdą domenę, spisz dane, zsumuj w Excelu. Codziennie.

Brak śledzenia linków między domenami. Mam sieć satelitów SEO — silniki-trojfazowe.pl linkuje do sklepu silniki-elektryczne.com.pl, torweb.pl linkuje do agencji copywriterskiej. W GSC widzę linki przychodzące, ale nie widzę mapy powiązań między własnymi domenami. A to kluczowe dla strategii linkowania.

Brak historii pozycji per fraza z wykresem. GSC pokazuje średnią pozycję dla zapytania w wybranym okresie. Chcę widzieć jak pozycja zmieniała się dzień po dniu — czy rośnie, czy spada, kiedy był skok. W GSC — nie ma takiego widoku.

Brak alertów o deindeksacji. Strona wypadła z indeksu — dowiem się o tym za tydzień, kiedy sprawdzę ręcznie. W międzyczasie traciłem ruch.

Brak porównań okres-do-okresu per fraza. GSC porównuje tylko zagregowane metryki. Chcę kliknąć konkretną frazę i zobaczyć: 30 dni temu miałeś pozycję 8.2, teraz masz 5.1, wzrost o 3.1 — z wykresem.

I najważniejsze: brak możliwości zautomatyzowania czegokolwiek. W GSC klikasz ręcznie. Nie da się podłączyć AI do analizy. Nie da się auto-wygenerować propozycji linkowania. Nie da się commitować zmian na GitHub z poziomu dashboardu analitycznego.

Zbudowałem własne narzędzie.

## Architektura — jedno miejsce na wszystko

SEO Command Center to full-stack aplikacja: Fastify + Prisma + PostgreSQL na backendzie, React + Vite + Tailwind + Recharts na frontendzie. Ciemny motyw w stylu Bloomberg terminal — kompaktowe dane, zero kolorowych distractorów, wszystko czytelne na pierwszy rzut oka.

<!-- SCREEN: Pełny widok dashboardu — sidebar z 23 domenami, karty statystyk, wykres ruchu, tabela domen -->

Backend odpytuje Google Search Console API raz dziennie i zapisuje dane do PostgreSQL. Osobna tabela na metryki dzienne per strona, osobna per domena, osobna na linki, eventy, alerty, frazy. 16 modeli w Prisma schema. Scheduler w node-cron odpala 6 jobów codziennie:

03:00 — crawl linków wewnętrznych i zewnętrznych na wszystkich 23 domenach. Cheerio parsuje HTML każdej strony z sitemapy, wyłapuje tagi `<a>`, rozróżnia linki wewnętrzne od zewnętrznych, sprawdza kody HTTP, wykrywa złamane linki i orphan pages.

06:00 — pull danych z GSC. Kliknięcia, wyświetlenia, CTR, pozycja per strona per dzień. Dla każdej z 23 domen.

07:00 — sync sitemap. Porównuje aktualny sitemap z bazą, wykrywa nowe i usunięte strony.

08:00 — check indexing. Sprawdza statusy indeksowania przez Google URL Inspection API.

09:00 — wykrywanie zmian pozycji. Porównuje ostatnie 7 dni z poprzednimi 7 dniami, generuje eventy: wejście do TOP 3, wypadnięcie z TOP 10, znaczące wzrosty i spadki.

10:00 — check śledzonych fraz kluczowych. Aktualizuje dane dla każdej frazy dodanej do monitoringu.

Nie klikam niczego ręcznie. Rano otwieram panel i wszystko jest aktualne.

## Dashboard — 23 domen na jednym ekranie

<!-- SCREEN: Dashboard z tabelą domen — kolumny: domena, indeksowanie %, kliknięcia, wyświetlenia, pozycja -->

Główny widok to tabela wszystkich domen z kluczowymi metrykami. Na pierwszy rzut oka widzę: Stojan Shop ma 4% indeksowania (53 z 1179 stron) i 1.9k kliknięć. MaturaPolski ma 30% i 86 kliknięć. Smart-Edu ma 100% i 143 kliknięcia.

Sidebar z listą domen scrolluje się niezależnie — przy 23 pozycjach to było kluczowe. Każda domena ma procent indeksowania kolorowany na zielono (100%), żółto (50+%) lub czerwono (poniżej 50%).

Klikam domenę — wchodzę w szczegóły.

## Domena w detalu — sześć zakładek na wszystko

Widok domeny to sześć zakładek: Strony, Zapytania, Śledzone, Linkowanie, Złamane linki, Orphan pages.

<!-- SCREEN: Widok domeny Stojan Shop — stats row + wykres ruchu 30 dni + breakdown indeksowania (PASS 341, NEUTRAL 9, UNKNOWN 837) -->

Stats row na górze: indeksowanie 4%, kliknięcia 1.9k, wyświetlenia 108.9k, średnia pozycja 9.2, alerty 3. Wykres ruchu z ostatnich 30 dni. Pod nim — przyciski z podziałem statusów indeksowania: PASS 341, NEUTRAL 9, UNKNOWN 837. Kliknięcie filtruje tabelę stron.

### Strony — rozwijane z frazami

<!-- SCREEN: Tab Strony z rozwiniętą stroną — lista fraz, kliknięcie na frazę otwiera mini wykres pozycji dziennej -->

Każda strona jest klikalna. Klikam wiersz — rozwija się lista fraz, na które ta strona rankuje. Dane z GSC, pobierane na żywo. Każda fraza jest też klikalna — klikam i widzę wykres pozycji dziennej z ostatnich 30 dni plus podsumowanie: kliknięcia, wyświetlenia, średnia pozycja.

Dwa poziomy rozwijania. Strona → frazy → wykres dzienny. Bez przeładowań, bez nowych widoków. Wszystko inline w tabeli.

Selektor okresu: 7d, 14d, 30d, 90d. Zmieniam — dane odświeżają się na żywo.

### Zapytania — paginacja i porównania

<!-- SCREEN: Tab Zapytania z rozwiniętą frazą — dwa wykresy (pozycja + kliknięcia), lista stron rankujących, toggle "vs poprzedni okres" z deltami -->

GSC pokazuje domyślnie 50 fraz. Mój panel pobiera do 5000 fraz z API, paginuje po 50, z wyszukiwarką. Każda fraza jest klikalna — rozwija się panel z dwoma wykresami (pozycja dziennie + kliknięcia dziennie), statystykami z porównaniem do poprzedniego okresu, i listą stron które rankują na tę frazę.

Toggle "vs poprzedni okres" — klikam i widzę delty. Fraza "rozprawka ai" miała 18 kliknięć w ciągu 30 dni, a w poprzednim okresie 12 — wzrost +6 (+50%). Pozycja z 1.7 na 1.3 — poprawa o 0.4. Na zielono.

### Śledzone frazy — monitoring per domena

<!-- SCREEN: Tab Śledzone — sekcja domain keywords z rozwiniętą frazą "silnik 3 kw", wykresy pozycji i kliknięć, tabela stron rankujących -->

Dwie sekcje. Pierwsza: śledzone frazy kluczowe per domena. Dodaję frazę "silnik 3 kw" — system natychmiast sprawdza w GSC jakie strony tej domeny rankują na tę frazę, na jakiej pozycji, ile kliknięć. Bez ręcznego odświeżania — dane pojawiają się od razu po dodaniu.

Klikam frazę — rozwija się panel z selektorem okresu (7d/14d/30d/90d), toggle "vs poprzedni okres" z deltami, dwoma wykresami (pozycja + kliknięcia), i tabelą stron.

Druga sekcja: śledzone URL-e. Dodaję konkretny URL — widzę historię pozycji, top zapytania (klikalne, z wykresami dziennymi), eventy SEO, backlinki.

### Linkowanie — anatomia sieci linków

<!-- SCREEN: Tab Linkowanie — stat cards + rozwinięta sekcja "Domeny linkujące do nas" z tabelą pogrupowaną per domena źródłowa, rowSpan -->

Pięć zwijanej sekcji. Domyślnie zamknięte — klikam nagłówek, otwiera się tabela.

Link Magnets — strony z największą liczbą linków przychodzących. Potrzebują linkowania — strony z ruchem ale bez linków wewnętrznych (orphan-like). Najwięcej linków wychodzących — strony rozsyłające link equity.

Domeny linkujące do nas — pogrupowane per domena źródłowa, z rowSpan. Widzę: silniki-trojfazowe.pl linkuje do Stojana 30 razy, agencja-copywriterska.pl 2 razy. Każdy link z anchorem, typem (dofollow/nofollow), statusem (live/lost), datą wykrycia.

Timeline backlinków — wizualny. Dwa widoki: oś czasu (pionowa linia z kolorowymi kropkami per domena źródłowa, data po lewej, szczegóły po prawej) i lista tabelaryczna. Plus wykres kumulacyjny i kalendarz heatmapa w stylu GitHub contributions.

<!-- SCREEN: Timeline backlinków — oś czasu z kolorowymi kropkami per domena, legenda na dole -->

Ograniczenie: panel wykrywa linki tylko między moimi 23 domenami. Zewnętrzne domeny (panoramafirm.pl, pkt.pl — GSC pokazuje ich 116 dla Stojana) nie są widoczne, bo crawler parsuje tylko moje strony. Rozwiązanie to integracja z płatnym API typu Ahrefs lub Moz — na liście do zrobienia.

### Timeline — wizualna historia zmian

<!-- SCREEN: Timeline z trzema widokami — wykres słupkowy (stacked bars: zielone/niebieskie/czerwone), kalendarz heatmapa, lista eventów -->

Trzy widoki przełączane ikonkami: wykres słupkowy (stacked bars: pozytywne eventy na zielono, neutralne na niebiesko, negatywne na czerwono), kalendarz heatmapa, lista chronologiczna.

Selektor okresu: 7d, 14d, 30d, 90d. Filtry per typ eventu — zaznaczam "Wejście do TOP 3" i "Wzrost pozycji" — wykres i kalendarz reagują, pokazując tylko te eventy.

Kliknięcie dnia na wykresie → przełącza do listy z filtrem na ten dzień. Kliknięcie dnia na kalendarzu — to samo. Interaktywny, powiązany.

Stat cards: Pozytywne 309, Negatywne 191, TOP 3 55, Backlinki 0, Łącznie 500. Dla MaturaPolski w 30 dni.

## AI Link Builder — Claude analizuje dane i commituje na GitHub

To najbardziej zaawansowany moduł. Claude Sonnet 4 dostaje pełne dane z panelu — strony, frazy, pozycje, istniejące linki — i proponuje konkretne cross-linki między domenami lub linki wewnętrzne w ramach domeny.

<!-- SCREEN: AI Link Builder — lista propozycji z diff viewerem, przyciskami Zatwierdź/Odrzuć, badge CROSSLINK/Wewnętrzny -->

Flow:

1. Konfiguruję repozytoria GitHub dla każdej domeny (jednorazowo, w panelu konfiguracji).
2. Wybieram domenę i klikam "Analizuj cross-linki" lub "Analizuj linki wewnętrzne".
3. Backend zbiera dane z bazy (strony z ruchem, frazy, istniejące linki), buduje prompt, wysyła do Claude API.
4. Claude analizuje dane i zwraca propozycje: strona źródłowa, strona docelowa, anchor text, uzasadnienie.
5. Dla każdej propozycji backend pobiera plik źródłowy z GitHub API, wysyła go do Claude z prośbą o wstawienie linku w naturalnym miejscu.
6. Propozycja z diff-em (czerwone linie = oryginał, zielone = zmiana) pojawia się w panelu.

<!-- SCREEN: Diff viewer — fragment kodu .astro z podświetloną zmianą (zielona linia z dodanym linkiem) -->

Klikam "Zatwierdź" — backend robi commit na GitHub przez API. Jeśli repo ma skonfigurowane GitHub Actions z `on: push` — deploy odpala się automatycznie. Strona Astro buduje się, sync do S3, invalidacja CloudFront. Za kilkadziesiąt sekund link jest live.

Klikam "Odrzuć" — propozycja znika. Claude nie jest nieomylny. Czasem proponuje link w złym miejscu, czasem anchor nie pasuje kontekstowo. Dlatego jest krok zatwierdzenia — AI proponuje, człowiek decyduje.

Dwa tryby analizy:

Cross-linki — Claude szuka okazji do linkowania MIĘDZY domenami. Np. artykuł o budowie silnika elektrycznego na blogu Stojana → link do kategorii "silniki trójfazowe" na silniki-trojfazowe.pl. Claude widzi dane z GSC, wie jakie frazy rankują, wie jakie strony mają ruch, i proponuje link z sensownym ancholem.

Linki wewnętrzne — Claude szuka okazji WEWNĄTRZ domeny. Strony z ruchem ale bez linków przychodzących (orphany), artykuły blogowe które mogłyby linkować do stron usługowych, kategorie które nie linkują do siebie nawzajem.

## Analityka API — kontrola kosztów

<!-- SCREEN: Analityka API — stat cards (koszt łącznie, requesty, tokeny), breakdown per feature, tabela logów z rozwiniętym wierszem -->

Każdy request do Claude API jest logowany: model, tokeny input/output, koszt, czas, feature, prompt preview, response preview. Wrapper `aiCall()` opakowuje standardowe wywołanie Anthropic SDK, kalkuluje koszt na podstawie cennika ($3/M input, $15/M output dla Sonnet 4) i zapisuje do tabeli `ApiLog`.

Breakdown per feature — widzę ile kosztowała analiza cross-linków vs generowanie kodu. Breakdown per model — gdybym chciał testować tańsze modele na mniej krytycznych zadaniach.

Wykres kosztów dziennie. Tabela logów z paginacją — klikam wiersz, widzę preview promptu i response.

## Stack technologiczny — dlaczego te wybory

Fastify, nie Express. Szybszy, lepszy TypeScript support, plugin system. Prisma jako ORM — schema-first podejście, auto-generowane typy, migracje. PostgreSQL zamiast SQLite — 30k+ wierszy danych GSC dziennie, relacje, indeksy, groupBy.

React + Vite + Tailwind na froncie. TanStack Query do cache'owania requestów — dane GSC nie zmieniają się co sekundę, `staleTime` pozwala uniknąć zbędnych requestów. Recharts do wykresów — lekki, dobrze integruje się z React.

Ciemny motyw z custom zmiennymi CSS — `panel-bg`, `panel-card`, `panel-border`, `accent-cyan`, `accent-amber`. JetBrains Mono na dane, DM Sans na nagłówki. Kompaktowe data-table z małym paddingiem — dużo danych na małej przestrzeni.

Deploy: EC2 t3.small (eu-central-1), PM2 z tsx (TSC ma OOM na t3.small — runtime compilation z tsx rozwiązuje problem). Nginx jako reverse proxy. Let's Encrypt na SSL. GitHub Actions do auto-deploy po push.

## Co jest dalej

Moduł generowania treści. Claude analizuje sitemapę domeny, strukturę artykułów, luki tematyczne — i proponuje nowe tematy do napisania. Nie sam artykuł (choć to też jest możliwe) — raczej brief: tytuł, frazy docelowe, sugerowana struktura, z jakich stron linkować i do jakich linkować.

Integracja z Ahrefs lub Moz API do wykrywania backlinków z domen spoza mojej sieci. Obecnie panel widzi tylko linki między 23 własnymi domenami — brakuje danych o 116 backlinkach które GSC pokazuje dla Stojana z panoramafirm.pl, pkt.pl i innych katalogów.

Automatyczne raporty AI generowane przez scheduler — codziennie lub co tydzień. Claude analizuje zmiany, identyfikuje trendy, generuje podsumowanie: "Stojan zyskał 3 pozycje na frazę 'silnik 3kw', MaturaPolski stracił 5 pozycji na 'matura polski testy', 2 nowe backlinki z silniki-trojfazowe.pl". Raport w panelu, opcjonalnie mail.

Na temat [zautomatyzowanego systemu Google Indexing API, który powiadamia Google o nowych i usuniętych stronach przy każdym deploymencie](/blog/google-indexing-api-lambda), pisałem osobno.

## Kiedy warto budować własne narzędzie SEO

Mój panel ma sens przy kilku warunkach. Masz wiele domen w jednym ekosystemie — satelity, zaplecza, network. Potrzebujesz widoku zbiorczego i porównań między domenami. Masz developera (lub jesteś developerem) który potrafi utrzymać integrację z GSC API przy zmianach. I — co kluczowe — chcesz zautomatyzować analizę i wdrożenie zmian, nie tylko raportowanie.

Nie ma sensu, kiedy masz jedną-dwie domeny (GSC wystarczy), nie masz technicznego zaplecza do utrzymania narzędzia, albo potrzebujesz danych o backlinkach z zewnętrznych domen (do tego służy Ahrefs, Semrush, Moz — i one robią to bardzo dobrze).

Moje narzędzie nie zastępuje tych platform. Uzupełnia je. Daje mi jedno miejsce, gdzie widzę wszystkie swoje domeny, z danymi przetwarzanymi pod moje potrzeby, z AI który proponuje zmiany i sam je wdraża. Tego nie da żaden gotowy tool.

Cały projekt: Fastify backend z 7 serwisami (GSC, indexing, sitemap, link crawler, timeline, analytics, AI), 7 endpointów route, Prisma schema z 16 modelami. React frontend z 9 stronami, dziesiątkami komponentów, wykresami, tabelami, diff viewerem. Scheduler z 6 codziennymi jobami. GitHub Actions CI/CD. I Claude Sonnet który commituje linki na GitHub.

Działa w produkcji na seo.torweb.pl. Dane odświeżają się automatycznie. Rano otwieram panel i wiem co się dzieje z moimi 23 domenami — bez otwierania 23 zakładek GSC.
