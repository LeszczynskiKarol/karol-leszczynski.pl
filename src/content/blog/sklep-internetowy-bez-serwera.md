---
title: "Sklep internetowy bez serwera — jak zbudowałem statyczny e-commerce w Astro, który przebudowuje się sam"
description: "Case study architektury, w której statyczna strona Astro SSG działa jako pełnoprawny sklep internetowy z koszykiem, płatnościami Stripe i automatycznym deployem po każdej zmianie stanu magazynowego. Bez backendu, bez bazy danych, za mniej niż dolar miesięcznie."
pubDate: 2026-03-13
heroImage: "/images/blog/astro-static-ecommerce.jpg"
heroImageAlt: "Schemat architektury statycznego sklepu Astro z pipeline CodeBuild i API sklepu bazowego"
category: "seo-techniczne"
tags:
  [
    "astro",
    "e-commerce",
    "aws",
    "codebuild",
    "static site",
    "sklep internetowy",
    "serverless",
    "case study",
  ]
draft: false
author: "Karol Leszczyński"
pillar: false
relatedPosts:
  ["jak-zbudowalem-15-stron-astro-aws-case-study", "astro-framework-przewodnik"]
---

Mam sklep z silnikami elektrycznymi na silniki-elektryczne.com.pl. Ponad 2000 produktów, Astro SSR z Node adapter, Fastify backend, PostgreSQL, integracja z Allegro, Stripe checkout, Google Merchant Feed. Pełnoprawny e-commerce z panelem admina, systemem zamówień i custom analytics.

Problem: chciałem sprzedawać silniki trójfazowe — wycinek oferty, kilkaset produktów — pod osobną, wyspecjalizowaną domeną silniki-trojfazowe.pl. Stawianie drugiego backendu, drugiej bazy danych i drugiego serwera EC2 dla kilku zamówień tygodniowo nie miało sensu ekonomicznego ani technicznego.

Rozwiązanie, które zbudowałem, jest nietypowe: silniki-trojfazowe.pl to w pełni statyczna strona Astro SSG — bez własnego serwera, bez bazy danych, bez backendu — która na etapie buildu pobiera produkty z API sklepu bazowego, generuje statyczne strony HTML dla każdego produktu, a po wdrożeniu obsługuje koszyk, checkout i płatności Stripe przez Lambda proxy. Strona przebudowuje się automatycznie po każdej zmianie stanu magazynowego w sklepie bazowym.

Koszt hostingu: poniżej dolara miesięcznie. Czas buildu: około 40 sekund. Lighthouse Performance: 98.

## Architektura — co z czym rozmawia

Cały system składa się z czterech warstw, które współpracują bez wspólnego serwera.

Pierwsza warstwa to sklep bazowy — silniki-elektryczne.com.pl — działający na EC2 z Astro SSR, backendem Fastify, bazą PostgreSQL i pełnym ekosystemem e-commerce (Allegro sync, Stripe, Google Merchant, SES mailing, panel admina). To jedyne miejsce, gdzie istnieje baza danych i logika serwerowa.

Druga warstwa to statyczna strona satelicka — silniki-trojfazowe.pl — zbudowana w Astro SSG. Na etapie buildu pobiera produkty z API sklepu bazowego (`/api/products?limit=2000`), filtruje tylko silniki trójfazowe, generuje statyczny HTML dla każdej strony: listing, strona produktu, strony filtrów mocy, checkout, regulaminy. Wynik to folder `dist/` z czystymi plikami HTML, CSS i minimalnym JavaScript dla interaktywnych komponentów (koszyk, formularz zamówienia).

Trzecia warstwa to AWS Lambda — proxy między statyczną stroną a Stripe checkout. Kiedy użytkownik klika „Kupuję i płacę", JavaScript na stronie wysyła request do Lambda, która tworzy sesję Stripe Checkout z danymi zamówienia i przekierowuje użytkownika do płatności. Po udanej płatności Stripe webhook trafia do backendu sklepu bazowego, który rezerwuje stock i wysyła maile. Lambda nie ma swojej bazy — deleguje wszystko do backendu bazowego.

Czwarta warstwa to pipeline automatycznej przebudowy — AWS CodeBuild + EventBridge. Kiedy w sklepie bazowym zmieni się stan magazynowy (nowe zamówienie, anulowanie, zmiana stocku przez admina), backend wywołuje `fireSatelliteRebuild()`, która triggeruje CodeBuild. CodeBuild pobiera kod z S3, odpala `npm run build` (Astro SSG), uploaduje wynik na S3 i invaliduje cache CloudFront. Jako fallback, EventBridge cron uruchamia rebuild co 30 minut — gdyby webhook nie zadziałał.

## Dane na etapie buildu — jak strona wie, co sprzedawać

Kluczowy element architektury to warstwa danych w `lib/api.ts`. Na etapie buildu Astro odpytuje API sklepu bazowego i pobiera pełną listę produktów. Potem filtruje ją funkcją `isEligible`, która sprawdza trzy warunki: produkt jest aktywny w sklepie (`marketplaces.ownStore.active`), ma przypisany slug, jest na stanie (`stock >= 1`) i należy do kategorii „trojfazowe".

Wynik filtrowania to tablica produktów, z której Astro generuje strony. Dynamiczny routing `[slug].astro` z `getStaticPaths()` tworzy stronę HTML dla każdego silnika. Strona główna wyciąga z danych popularne moce i rozkład stanów (nowy/używany). Strony `/moc/[slug]` grupują produkty po mocy.

Jeśli produkt zostanie sprzedany i stock spadnie do zera, przy następnym buildzie `isEligible` go odrzuci i strona produktu zniknie. Jeśli admin doda nowy silnik trójfazowy, pojawi się automatycznie. Zero interwencji manualnej.

Produkty są cache'owane w pamięci podczas buildu — zmienne `_cached` zapobiegają wielokrotnemu odpytywaniu API dla tych samych danych. Build trwa około 40 sekund dla kilkuset produktów.

## Koszyk i checkout — interaktywność na statycznej stronie

Tu pojawia się pytanie, które zadaje każdy, kto słyszy o statycznym e-commerce: „Jak obsłużyć koszyk bez backendu?".

Koszyk żyje w `localStorage` przeglądarki. Komponent React `CartDropdown` (Island, hydrowany przez `client:load`) czyta i zapisuje do `localStorage` pod kluczem `silnik_cart`. Każda zmiana emituje `CustomEvent('cart-updated')`, a wszystkie komponenty koszyka nasłuchują tego eventu i re-renderują się. Synchronizacja między komponentami odbywa się przez DOM events, nie przez serwer.

Checkout to formularz React (`CheckoutForm`) z walidacją po stronie klienta: imię, nazwisko, email, telefon, adres, kod pocztowy, NIP dla firm. Formularz zapisuje się do `sessionStorage` na bieżąco — jeśli użytkownik zamknie kartę i wróci, dane są zachowane. Jeśli Stripe anuluje sesję, użytkownik wraca na `/checkout?stripe_cancel=true` i widzi komunikat z zachowanymi danymi.

Koszt wysyłki liczony jest dynamicznie — formularz odpytuje API sklepu bazowego (`/api/orders/calculate-shipping`) z listą produktów i metodą płatności. Backend bazowy ma konfigurację progów wagowych i cen wysyłki. Strona satelicka nie musi tej logiki znać — pyta i dostaje odpowiedź.

Dwie metody płatności: przelew online (Stripe Checkout z BLIK, kartą, P24, Google Pay i Apple Pay) oraz za pobraniem (dostępne do 575 kg). Wybór metody wpływa na koszt wysyłki w czasie rzeczywistym.

## Stripe i Lambda — jak statyczna strona obsługuje płatności

Kiedy użytkownik klika „Kupuję i płacę", JavaScript wysyła POST do Lambda (`create-checkout`) z danymi koszyka, adresem i metodą płatności.

Lambda proxy działa jak pośrednik. Przekazuje dane do backendu sklepu bazowego (`/api/orders`), który waliduje produkty, sprawdza stock, weryfikuje ceny i tworzy zamówienie w PostgreSQL. Dla płatności online backend tworzy sesję Stripe Checkout i zwraca URL. Lambda odsyła ten URL do frontendu, który przekierowuje użytkownika do Stripe.

Kluczowy detal: `success_url` i `cancel_url` w sesji Stripe wskazują na domenę satelicką (`silniki-trojfazowe.pl/checkout/sukces`), nie na sklep bazowy. Użytkownik nigdy nie widzi silniki-elektryczne.com.pl. Z jego perspektywy kupuje w jednym spójnym sklepie.

Dla płatności za pobraniem Lambda od razu tworzy zamówienie ze statusem „paid" (bo fizyczne pobranie nastąpi przy dostawie), rezerwuje stock w bazie i zwraca potwierdzenie. Klient widzi stronę sukcesu bez pośrednictwa Stripe.

Po udanej płatności online Stripe webhook trafia do backendu bazowego, który rezerwuje stock, wysyła maile potwierdzające (SES) i triggeruje `fireSatelliteRebuild()` — żeby strona satelicka przebudowała się z aktualnym stanem magazynowym.

## Automatyczny rebuild — strona, która się aktualizuje

To element, który zamienia statyczną stronę w żywy organizm. W backendzie sklepu bazowego istnieje serwis `rebuild-satellite.ts`, który triggeruje CodeBuild dla obu stron satelickich (silnik-elektryczny.pl i silniki-trojfazowe.pl) przy każdej istotnej zmianie.

Eventy, które triggerują rebuild: nowe zamówienie (stock się zmienił), anulowanie zamówienia (stock przywrócony), zmiana ceny produktu w panelu admina, dodanie lub usunięcie produktu, zmiana nazwy produktu, oraz ręczna zmiana stocku.

Serwis ma wbudowany debounce — minimum 2 minuty między triggerami. Jeśli admin zmieni 10 produktów w ciągu minuty, CodeBuild odpali się raz, nie dziesięć razy. Dodatkowo, przed triggerem sprawdza, czy build nie trwa już (`IN_PROGRESS`) — jeśli tak, pomija.

Jako fallback, EventBridge cron triggeruje rebuild co 30 minut — na wypadek, gdyby webhook nie dotarł (np. przez chwilowy problem z siecią).

Cały pipeline CodeBuild to cztery kroki: `npm ci` (instalacja zależności), `npm run build` (Astro SSG generuje `dist/`), `aws s3 sync` (upload na S3 z rozdzieleniem cache — HTML bez cache, assety z immutable cache na rok), `aws cloudfront create-invalidation` (flush CDN). Od triggera do nowej wersji na produkcji mija 40–60 sekund.

## SEO — dlaczego to działa lepiej niż tradycyjny sklep

Strona satelicka ma kilka przewag SEO nad sklepem bazowym.

Po pierwsze, wyspecjalizowanie. silniki-trojfazowe.pl jest tematycznie węższe niż silniki-elektryczne.com.pl. Google preferuje strony, które są ekspertami w jednym temacie. Strona o silnikach trójfazowych, z domeną zawierającą frazę „silniki-trojfazowe", z treściami wyłącznie o silnikach trójfazowych — to silny sygnał topical authority.

Po drugie, szybkość. Statyczny HTML serwowany z CloudFront CDN ładuje się szybciej niż dynamiczne strony renderowane przez Node.js SSR. Core Web Vitals na satelicie są mierzalnie lepsze.

Po trzecie, czysty HTML. Googlebot widzi pełną treść strony bez renderowania JavaScript. Product schema z JSON-LD, breadcrumbs z BreadcrumbList, kanoniczne URL — wszystko wygenerowane na etapie buildu.

Każda strona produktu ma kompletne schema Product z ceną, dostępnością, marką, wagą, kategorią, breadcrumbem od strony głównej przez kategorię i moc do nazwy produktu. Strona główna ma schema Store z AggregateOffer. Sitemap generowany automatycznie przez `@astrojs/sitemap`.

## Kiedy ten model ma sens — a kiedy nie

Statyczny sklep satelicki sprawdza się w konkretnych warunkach. Musisz mieć istniejący sklep bazowy z API, z którego możesz pobierać dane. Sprzedaż na satelicie musi być na tyle niska, że częste rebuildy (co zmianę stocku + cron co 30 minut) nie generują znaczących kosztów. Produkty nie mogą zmieniać się co sekundę — jeśli masz aukcje real-time z cenami zmieniającymi się co minutę, statyczny build nie nadąży.

Model idealnie pasuje do: wyspecjalizowanych podsklepów (silniki trójfazowe z oferty ogólnej, używane silniki, silniki konkretnej marki), stron zapleczowych z funkcją sprzedażową (strona o silnikach z możliwością kupna, nie tylko informacyjna), i niszowych e-commerce z kilkudziesięcioma do kilkuset produktami i kilkoma zamówieniami dziennie.

Model nie pasuje do: sklepów z tysiącami zamówień dziennie (każde zamówienie triggeruje rebuild — kosztowo i czasowo), produktów z dynamicznymi cenami (stock aukcyjny, przetargi), personalizacji w czasie rzeczywistym (rekomendacje, ceny per użytkownik).

## Koszty — twarde dane

Hosting S3 + CloudFront dla satelity kosztuje poniżej jednego dolara miesięcznie. CodeBuild — darmowy free tier pokrywa 100 minut buildu miesięcznie. Przy 40-sekundowym buildzie i 48 buildach dziennie (cron co 30 minut) plus kilka triggerów ze zmian stocku, miesięcznie zużywam około 40 minut. Mieści się w free tier z zapasem.

Lambda proxy — kilka wywołań dziennie, free tier. Route 53 hosted zone — 0,50 USD/mies. ACM certyfikat — darmowy.

Porównaj z postawieniem drugiego serwera EC2 (t3.small, ~15 USD/mies), drugiej bazy RDS (~15 USD/mies), utrzymaniem kodu backendu, aktualizacjami bezpieczeństwa i monitoringiem. Dla kilku zamówień tygodniowo różnica to 30+ dolarów miesięcznie za infrastrukturę, której nie potrzebujesz.

## Co bym zmienił

Po kilku miesiącach produkcji widzę rzeczy do poprawienia. Największa to brak real-time stock validation na etapie checkout. Między ostatnim buildem a momentem kliknięcia „Kupuję" mogło minąć do 30 minut — w tym czasie ktoś mógł kupić ostatnią sztukę w sklepie bazowym. Backend bazowy waliduje stock przy tworzeniu zamówienia i zwraca błąd, ale UX byłby lepszy z asynchronicznym sprawdzeniem stocku przed wysłaniem formularza.

Druga rzecz to brak integracji z Google Analytics sklepu bazowego. Konwersje na satelicie są oddzielone od konwersji na sklepie bazowym. Ujednolicenie analytics wymaga wspólnego measurement ID lub server-side tracking z Lambda.

Trzecia: buildspec.yml mógłby cachować `node_modules` w S3, żeby przyspieszyć fazę `npm ci`. Przy 40-sekundowym buildzie nie jest to krytyczne, ale przy większej liczbie satelitów miałoby sens.

## Jak postawić analogiczny sklep

Jeśli masz sklep z API i chcesz wydzielić niszę pod osobną domenę, potrzebujesz pięciu elementów.

Pierwszy: Astro SSG z `lib/api.ts`, który pobiera dane z Twojego API i filtruje produkty. Filtr to jedna funkcja (`isEligible`) — zmieniasz warunki i masz inny wycinek oferty.

Drugi: komponenty React jako Astro Islands — `CartDropdown` (koszyk w localStorage), `AddToCart` (przycisk dodawania), `CheckoutForm` (formularz zamówienia). Wszystkie działają bez serwera, komunikują się z API bazowego sklepu.

Trzeci: Lambda proxy do tworzenia sesji Stripe Checkout — kilkanaście linii kodu, deleguje logikę do backendu bazowego.

Czwarty: `fireSatelliteRebuild()` w backendzie bazowego sklepu — wywoływany przy zmianach stocku, triggeruje CodeBuild.

Piąty: infrastruktura AWS (S3 + CloudFront + CodeBuild + EventBridge) — skrypt `setup.sh` konfiguruje to w kilka minut.

Cała strona satelicka to ~15 plików TypeScript/Astro. Nie ma bazy danych, nie ma backendu, nie ma panelu admina. Produkty zarządzasz w sklepie bazowym — satelita przebudowuje się sama.

Jest to podejście, które zamienia koszty stałe (serwer, baza, utrzymanie) w koszty zerowe (statyczny hosting) kosztem kilkudziesięciu sekund opóźnienia między zmianą a jej widocznością na stronie. Dla niszowego e-commerce z kilkoma zamówieniami dziennie to optymalna wymiana.
