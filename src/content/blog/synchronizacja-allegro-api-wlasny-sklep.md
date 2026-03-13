---
title: "Synchronizacja Allegro ↔ własny sklep — jak zbudowałem bidirectional sync, którego nie da Ci żadna wtyczka"
description: "Case study z budowy własnej, dwukierunkowej synchronizacji między sklepem e-commerce (Fastify + Prisma + PostgreSQL) a Allegro. OAuth, stock sync, automatyczna publikacja ofert z rollbackiem, event polling, matching produktów po nazwach i panel admina do zarządzania powiązaniami."
pubDate: 2026-03-13
heroImage: "/images/blog/allegro-sync-architecture.jpg"
heroImageAlt: "Schemat dwukierunkowej synchronizacji między własnym sklepem a Allegro"
category: "seo-techniczne"
tags:
  [
    "allegro",
    "api",
    "e-commerce",
    "synchronizacja",
    "fastify",
    "typescript",
    "integracja",
    "case study",
  ]
draft: false
author: "Karol Leszczyński"
pillar: false
relatedPosts: ["sklep-bez-serwera-statyczny-ecommerce-astro"]
---

Klient sprzedaje silniki elektryczne. Kilkaset sztuk w magazynie, dwa kanały sprzedaży: własny sklep internetowy i Allegro. Przy dwóch-trzech zamówieniach dziennie ręczna synchronizacja stanów magazynowych była uciążliwa, ale do ogarnięcia. Otwierasz panel sklepu, otwierasz panel Allegro, po każdym zamówieniu ręcznie zmniejszasz stock w drugim kanale. Irytujące, ale wykonalne.

Problem zaczął się, kiedy zamówień zrobiło się więcej. Klient sprzedaje ten sam silnik jednocześnie na Allegro i w sklepie. Ktoś kupuje ostatnią sztukę na Allegro, a trzy minuty później ktoś inny kupuje tę samą sztukę w sklepie — bo stock nie zdążył się zaktualizować. Overselling. Przeprosiny do klienta, zwrot pieniędzy, utrata reputacji.

Gotowe rozwiązania? BaseLinker pobiera opłatę miesięczną i nie daje pełnej kontroli nad logiką matchowania produktów. Wtyczki WooCommerce nie działają z własnym backendem w Fastify. Allegro API jest dobrze udokumentowane, ale wymaga zbudowania całej warstwy autoryzacji, odświeżania tokenów i obsługi błędów od zera.

Zbudowałem własną, dwukierunkową synchronizację. Od zera. W TypeScript, na Fastify z Prisma i PostgreSQL. Działa w produkcji od wielu miesięcy.

## Architektura — co z czym rozmawia

Cały system składa się z pięciu warstw, które razem tworzą pętlę synchronizacji.

Pierwsza to warstwa autoryzacji — OAuth 2.0 client z automatycznym odświeżaniem tokenów. Allegro wymaga tokenu dostępu, który wygasa co 12 godzin. Mój klient OAuth przechowuje tokeny w PostgreSQL (model `AllegroToken`), odświeża je automatycznie 5 minut przed wygaśnięciem i obsługuje retry z exponential backoff przy błędach 503.

Druga to warstwa synchronizacji sklep → Allegro. Kiedy cokolwiek zmienia się w sklepie (zamówienie, anulowanie, zmiana stocku przez admina, zmiana nazwy produktu), system automatycznie wysyła aktualizację do Allegro. Fire-and-forget — nigdy nie blokuje głównego flow zamówienia.

Trzecia to warstwa synchronizacji Allegro → sklep. Scheduler co 3 minuty odpytuje Allegro o nowe eventy (zmiany stocku po sprzedaży na Allegro) i aktualizuje stany w bazie sklepu.

Czwarta to warstwa publikacji — automatyczne tworzenie nowych ofert na Allegro z panelu admina sklepu, z mapowaniem parametrów (moc, obroty, producent, waga) na kategorie i atrybuty Allegro.

Piąta to panel administracyjny — React dashboard do zarządzania powiązaniami między produktami sklepowymi a ofertami Allegro, z filtrowaniem, wyszukiwaniem, ręcznym linkowaniem i podglądem rozbieżności stanów.

## OAuth i zarządzanie tokenami — fundament, który musi działać bezawaryjnie

Allegro używa OAuth 2.0 z authorization code flow. Użytkownik (admin sklepu) klika „Połącz z Allegro" w panelu, zostaje przekierowany na stronę Allegro, loguje się i autoryzuje aplikację. Allegro przekierowuje z powrotem na callback URL z kodem autoryzacyjnym. Backend wymienia kod na parę tokenów: access token (ważny 12h) i refresh token (ważny do odwołania).

Kluczowy problem: access token wygasa. Jeśli synchronizacja odpala się o 3 w nocy i token wygasł, cały sync staje. Moje rozwiązanie: przed każdym requestem do API Allegro sprawdzam, czy token wygaśnie w ciągu najbliższych 5 minut. Jeśli tak — odświeżam go refresh tokenem i zapisuję nową parę do bazy. Jeśli odświeżanie się nie powiedzie (np. użytkownik odwołał uprawnienia w panelu Allegro), system loguje błąd, ale nie crashuje — reszta sklepu działa normalnie.

Dodatkowo, każdy request do Allegro API ma retry logic: przy błędzie 503 (service temporarily unavailable) czeka z exponential backoff (1s, 2s, 4s) i ponawia do 3 razy. Przy 401 (unauthorized) próbuje raz odświeżyć token i ponawia request. To brzmi jak detal, ale w produkcji Allegro API bywa niestabilne — bez retry logic sync padałby kilka razy w tygodniu.

Tak wygląda w praktyce — fragment mojego klienta API Allegro z retry logic i auto-refresh tokenów:

```typescript
// backend/src/lib/allegro-client.ts — fragment allegroFetch()
export async function allegroFetch<T = any>(
  path: string,
  options: AllegroRequestOptions = {},
): Promise<T> {
  const { method = "GET", body, retries = 3 } = options;

  for (let attempt = 0; attempt < retries; attempt++) {
    const token = await getAccessToken();

    const res = await fetch(`${allegroConfig.apiUrl}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/vnd.allegro.public.v1+json",
        Accept: "application/vnd.allegro.public.v1+json",
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });

    // 503 — retry z exponential backoff
    if (res.status === 503 && attempt < retries - 1) {
      const delay = Math.pow(2, attempt) * 1000;
      await new Promise((r) => setTimeout(r, delay));
      continue;
    }

    // 401 — odśwież token i spróbuj raz jeszcze
    if (res.status === 401 && attempt === 0) {
      const latestToken = await getLatestToken();
      if (latestToken) {
        await refreshAccessToken(latestToken.refreshToken);
        continue;
      }
    }

    if (!res.ok) {
      const errorText = await res.text();
      throw new Error(`Allegro API error ${res.status}: ${errorText}`);
    }

    const text = await res.text();
    if (!text) return {} as T;
    return JSON.parse(text) as T;
  }

  throw new Error(`Allegro API failed after ${retries} retries`);
}
```

## Sklep → Allegro — push zmian w czasie rzeczywistym

Synchronizacja w kierunku sklep → Allegro odbywa się przez system hooków. W kodzie backendu, wszędzie tam, gdzie zmienia się stan produktu, wywołuję funkcje `fireAllegroStockSync()` i `fireAllegroNameSync()`. Są to wrappery fire-and-forget — nigdy nie rzucają wyjątku, nigdy nie blokują głównego flow.

Eventy, które triggerują sync: nowe zamówienie (stock maleje po rezerwacji), anulowanie zamówienia (stock wraca), zmiana stocku przez admina w panelu, zmiana nazwy produktu, i zmiana ceny (opcjonalnie).

Logika synchronizacji stocku jest niebanalna, bo Allegro ma koncept aktywnych i zakończonych ofert. Kiedy stock spada do zera, nie wystarczy ustawić `stock: 0` — trzeba też zakończyć (deaktywować) ofertę, bo Allegro nie wyświetla ofert z zerowym stanem. Kiedy stock wraca powyżej zera (np. po anulowaniu zamówienia), trzeba najpierw reaktywować ofertę, poczekać 1,5 sekundy (Allegro potrzebuje czasu na przetworzenie), a dopiero potem ustawić nowy stock.

Ta sekwencja — reaktywacja → wait → stock update — wymagała kilku iteracji debugowania. Bez wait Allegro zwracał błąd, bo oferta nie zdążyła się aktywować. Zbyt krótki wait (500ms) działał w 80% przypadków. 1500ms działa stabilnie.

Oto kod, który obsługuje tę logikę — reaktywacja, wait, stock update:

```typescript
// backend/src/services/allegro-sync.ts — syncStockToAllegro()
export async function syncStockToAllegro(
  productId: string,
  newStock: number,
): Promise<void> {
  const product = await prisma.product.findUnique({
    where: { id: productId },
    select: { id: true, name: true, marketplaces: true },
  });
  if (!product) return;

  const mp = product.marketplaces as any;
  const allegroId = mp?.allegro?.productId;
  if (!allegroId) return;

  if (newStock <= 0) {
    // Stock = 0 → ustaw 0, potem ZAKOŃCZ ofertę
    await patchOffer(allegroId, { stock: { available: 0, unit: "UNIT" } });
    await endOffer(allegroId);
    // Zapisz allegro.active = false
  } else {
    // Stock > 0 → REAKTYWUJ jeśli była zakończona, potem ustaw stock
    if (mp?.allegro?.active === false) {
      await activateOffer(allegroId);
      await new Promise((r) => setTimeout(r, 1500)); // Allegro potrzebuje czasu
    }
    await patchOffer(allegroId, {
      stock: { available: newStock, unit: "UNIT" },
    });
    // Zapisz allegro.active = true
  }
}
```

## Allegro → Sklep — event polling i automatyczna aktualizacja

Synchronizacja w odwrotnym kierunku opiera się na Allegro Offer Events API. Co 3 minuty scheduler odpytuje endpoint z eventami i szuka zmian typu `OFFER_STOCK_CHANGED`. Kiedy ktoś kupił silnik na Allegro, event zawiera ID oferty — system znajduje powiązany produkt w bazie sklepu i aktualizuje stock.

Ważna decyzja projektowa: celowo ignoruję eventy `OFFER_PRICE_CHANGED`. Ceny zarządzane są wyłącznie w panelu sklepu — nie chcę, żeby przypadkowa zmiana ceny na Allegro (np. przez promocję) nadpisała cenę w sklepie. To jednokierunkowa synchronizacja cen: sklep → Allegro, nigdy odwrotnie.

System zapamiętuje ID ostatniego przetworzonego eventu w tabeli `Setting` w PostgreSQL. Dzięki temu po restarcie serwera nie przetwarza tych samych eventów ponownie. Przy pierwszym uruchomieniu (brak zapisanego ID) pobiera ostatnie 100 eventów.

Jako dodatkowe zabezpieczenie, raz na 24 godziny uruchamia się detekcja osieroconych powiązań. System pobiera wszystkie oferty sprzedawcy z Allegro i porównuje z powiązaniami w bazie. Jeśli oferta została usunięta na Allegro (np. przez moderację), ale powiązanie w bazie nadal istnieje — system je usuwa i loguje ostrzeżenie.

## Matching produktów — dlaczego „silnik 11kW INDUKTA MS" nie matchował się z „silnik 11kW 3fazowy INDUKTA"

To był jeden z najbardziej frustrujących problemów. Mam ten sam fizyczny silnik w sklepie i na Allegro, ale nazwy się różnią. W sklepie: „silnik elektryczny 11kW 2950obr. 3fazowy INDUKTA". Na Allegro: „silnik elektryczny 11kW 2950obr. INDUKTA MS". Różnice: sklep ma „3fazowy" (bo to informacja dla klienta), Allegro ma „MS" (bo to oznaczenie serii producenta dodane przy publikacji).

Pierwszy import z Allegro dopasował 60% produktów. Reszta miała status „Brak powiązania", mimo że fizycznie te same silniki leżały w magazynie.

Rozwiązaniem jest funkcja normalizacji nazw. Przed porównaniem obie nazwy przechodzą przez pipeline: lowercase, usunięcie „3fazowy" i „trojfazowy" (redundantne w kontekście silników), usunięcie oznaczeń serii „MS" i „OMT" z końca nazwy, zamiana przecinków na kropki w mocach, usunięcie wielokrotnych spacji, i trim. Po normalizacji „silnik elektryczny 11kw 2950obr indukta" z obu źródeł jest identyczne — match.

Normalizacja nie rozwiązuje 100% przypadków. Niektóre produkty mają na Allegro zupełnie inną nazwę (np. ze względu na limity znaków — 75 max). Dla tych przypadków panel admina pozwala ręcznie powiązać produkt z ofertą Allegro.

## Automatyczna publikacja na Allegro — z rollbackiem

Jedna z bardziej zaawansowanych funkcji: admin dodaje nowy produkt w panelu sklepu, zaznacza checkbox „Dodaj też na Allegro", i system automatycznie tworzy ofertę na Allegro z prawidłowymi parametrami.

Mapowanie parametrów to osobna warstwa konfiguracji. Allegro wymaga specyficznych ID parametrów per kategoria. Silnik trójfazowy ma inne parametry niż motoreduktor. Moc silnika to parametr `219137`, obroty to `219153`, napięcie to `219165`, waga to `214478`. Producent to parametr `248929` z gigantycznym słownikiem — ponad 30 000 wartości (ABB, Siemens, SEW, Tamel, INDUKTA itd.), każda z własnym ID.

Konfiguracja shipping jest równie złożona. Allegro Smart! ma osobne cenniki wysyłkowe per próg wagowy. Silnik 3 kg idzie innym cennikiem niż silnik 90 kg. System automatycznie dobiera właściwy cennik na podstawie wagi produktu.

Najciekawszy element to rollback. Jeśli Allegro API odrzuci ofertę (błąd walidacji, brakujący parametr, przekroczony limit znaków w nazwie), system automatycznie usuwa produkt ze sklepu — żeby nie było sytuacji, gdzie produkt jest w sklepie, ale nie ma go na Allegro, a admin o tym nie wie. Zamiast tego admin dostaje jasny komunikat z błędem Allegro i może poprawić dane.

Ta decyzja projektowa — rollback przy błędzie Allegro — wydaje się kontrowersyjna (czemu usuwać z własnego sklepu?), ale w praktyce działa świetnie. Admin od razu widzi problem i go naprawia, zamiast odkrywać po tygodniu, że oferta nigdy nie trafiła na Allegro.

## Panel administracyjny — jedno miejsce do zarządzania dwoma kanałami

Panel Allegro to komponent React renderowany w layoutzie admina. Na jednym ekranie admin widzi: statystyki (ile ofert łącznie, ile powiązanych, ile bez powiązania, ile z zerowym stockiem, ile z rozbieżnymi stanami), pełną listę ofert Allegro z informacją o powiązaniu z produktem sklepowym, filtrowanie (wszystkie, powiązane, bez powiązania, zerowy stock, rozbieżne stany), wyszukiwanie po nazwie i ID oferty, oraz akcje zbiorcze (import, rekoncyliacja, pobranie zdarzeń).

Kluczowa kolumna w tabeli to „Sklep ↔ Allegro" — porównanie stanów magazynowych. Zielony checkmark oznacza zgodność. Czerwona lub żółta etykietka z liczbą (np. „+3" lub „-2") oznacza rozbieżność: sklep ma więcej lub mniej niż Allegro. Admin widzi problem na pierwszy rzut oka i może uruchomić rekoncyliację jednym kliknięciem.

Przy każdym produkcie w głównej tabeli produktów sklepu jest minikomponent z badgem Allegro: zielona kropka (oferta aktywna), szara kropka (nieaktywna), link do oferty na Allegro i przycisk ręcznej synchronizacji. Jedno kliknięcie wysuwa aktualny stock na Allegro.

## Scheduler — background tasks bez Kubernetes

Nie używam kolejek (BullMQ, RabbitMQ) ani orkiestratorów (Kubernetes CronJobs) do zadań w tle. Prosty `setInterval` w Node.js wystarczy dla mojej skali.

Trzy zaplanowane zadania: event polling co 3 minuty (sprawdza nowe eventy na Allegro), detekcja osieroconych powiązań co 24 godziny (porównuje oferty Allegro z powiązaniami w bazie), oraz jednorazowy poll 30 sekund po starcie serwera (żeby nadgonić eventy, które mogły się pojawić podczas restartu).

Pełna rekoncyliacja (porównanie stanów ALL produktów z Allegro) jest celowo manualna — uruchamia się tylko z panelu admina. Powód: rekoncyliacja wykonuje jeden request do Allegro API per produkt. Przy 500 powiązanych produktach to 500 requestów — zbyt dużo, żeby uruchamiać to automatycznie co godzinę. Admin robi to raz na tydzień albo gdy podejrzewa problem.

Graceful shutdown zamyka scheduler przy `SIGTERM`/`SIGINT` — żaden request do Allegro nie zostaje „wiszący" po restarcie serwera.

## Flow zamówienia — jak to wszystko działa razem

Pokażę pełny flow na przykładzie zamówienia silnika 11kW.

Klient składa zamówienie w sklepie. Backend waliduje stock, tworzy zamówienie w PostgreSQL, przekierowuje do Stripe Checkout. Klient płaci BLIK. Stripe webhook trafia do backendu. Backend rezerwuje stock (decrement w bazie). Natychmiast po rezerwacji odpalają się dwa hooki: `fireAllegroStockSync(productId, newStock)` — push nowego stanu na Allegro, i `fireSatelliteRebuild("stock_reserved")` — trigger rebuildu stron satelickich. Maile potwierdzające idą do klienta i admina przez SES.

Na Allegro oferta silnika 11kW automatycznie aktualizuje się — stock zmniejszony o 1. Jeśli to była ostatnia sztuka, oferta zostaje zakończona (deaktywowana). Strony satelickie (silnik-elektryczny.pl, silniki-trojfazowe.pl) przebudowują się z nowym stanem — produkt znika lub pokazuje aktualny stock.

Gdyby w tym samym momencie ktoś kupił ten silnik na Allegro, event polling po 3 minutach wyłapie zmianę stocku i zsynchronizuje bazę sklepu. Overselling jest teoretycznie możliwy w oknie 3 minut — ale w praktyce przy kilku zamówieniach dziennie na niszowe silniki elektryczne to ryzyko jest akceptowalne.

## Czego się nauczyłem

Po wielu miesiącach produkcji z tym systemem mam kilka obserwacji, które mogą zaoszczędzić komuś czasu.

Allegro API jest dobrze udokumentowane, ale pełne pułapek. Endpoint `PATCH /sale/product-offers` nie obsługuje zmiany statusu publikacji — do tego potrzebny jest osobny endpoint `PUT /sale/offer-publication-commands`. Odkryłem to po godzinie debugowania, dlaczego deaktywacja oferty nie działa. Nazwy ofert mają limit 75 znaków — obcinanie w kodzie jest konieczne, bo API zwróci 422 bez wyjaśnienia. Content-Type musi być `application/vnd.allegro.public.v1+json`, nie zwykły `application/json`.

Retry logic to nie lukier — to konieczność. Allegro API zwraca 503 częściej niż byś się spodziewał. Bez retry system traciłby po kilka sync eventów tygodniowo.

Fire-and-forget to jedyny sensowny wzorzec dla hooków synchronizacji. Klient nie może czekać na odpowiedź z Allegro API (300–800ms) przy składaniu zamówienia. Synchronizacja musi się odbyć asynchronicznie, a błędy muszą być logowane, nie rzucane.

Rollback przy publikacji to kontrowersyjna, ale sprawdzona decyzja. Lepiej, żeby admin zobaczył błąd od razu, niż żeby produkt „wisiał" w sklepie bez oferty na Allegro.

Słownik producentów Allegro ma ponad 30 000 pozycji. Matchowanie nazwy producenta z Twojej bazy do ID wartości parametru Allegro wymaga osobnej konfiguracji. Przygotuj się na ręczne mapowanie mniej popularnych marek.

Cały plik hooków — 15 linii kodu, które łączą zamówienia z Allegro:

```typescript
// backend/src/services/allegro-hooks.ts — cały plik
import { syncStockToAllegro, syncNameToAllegro } from "./allegro-sync.js";

export function fireAllegroStockSync(
  productId: string,
  newStock: number,
): void {
  syncStockToAllegro(productId, newStock).catch((err) =>
    console.error(
      `[allegro-hook] stock sync failed for ${productId}:`,
      err.message,
    ),
  );
}

export function fireAllegroNameSync(productId: string, newName: string): void {
  syncNameToAllegro(productId, newName).catch((err) =>
    console.error(
      `[allegro-hook] name sync failed for ${productId}:`,
      err.message,
    ),
  );
}
```

## Kiedy ten model ma sens

Własna integracja z Allegro ma sens, kiedy: masz własny backend (nie WordPress/WooCommerce — tam użyj BaseLinker), potrzebujesz pełnej kontroli nad logiką matchowania i synchronizacji, sprzedajesz na Allegro i we własnym sklepie jednocześnie, i masz developera (lub jesteś developerem), który jest w stanie utrzymywać kod integracji przy zmianach w API Allegro.

Nie ma sensu, kiedy: sprzedajesz wyłącznie na Allegro (bez własnego sklepu), używasz gotowego CMS z ekosystemem wtyczek (WooCommerce + BaseLinker rozwiąże 90% problemów taniej), albo nie masz zasobów na utrzymanie custom integracji.

Moja integracja to kilka tysięcy linii TypeScript — nie jest trywialna. Ale daje coś, czego żadna wtyczka nie da: pełną kontrolę nad tym, co, kiedy i jak się synchronizuje, z logiką dopasowaną do specyfiki produktu (silniki elektryczne z ich mocami, obrotami, wielkościami mechanicznymi i oznaczeniami serii producentów).
