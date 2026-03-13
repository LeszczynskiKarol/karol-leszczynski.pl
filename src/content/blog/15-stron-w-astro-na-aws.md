---
title: "Jak zbudowałem 15+ stron w Astro na AWS za mniej niż 1 dolar miesięcznie — case study full-stack developera"
description: "Case study z budowy statycznych stron internetowych w frameworku Astro z hostingiem na AWS S3 + CloudFront. Lighthouse 95–100, koszt hostingu poniżej 1 USD/mies, zero JavaScriptu, pełna kontrola SEO. Konkretne dane, błędy i wnioski z ponad roku produkcji."
pubDate: 2026-03-12
heroImage: "/images/blog/astro-aws-case-study.jpg"
heroImageAlt: "Terminal z kodem Astro i panelem AWS CloudFront — budowa statycznych stron internetowych"
category: "seo-techniczne"
tags:
  [
    "astro",
    "aws",
    "statyczna strona",
    "s3",
    "cloudfront",
    "core web vitals",
    "case study",
    "hosting",
  ]
draft: false
author: "Karol Leszczyński"
pillar: false
relatedPosts: []
---

WordPress się pali.

Mówię to po piętnastu latach pracy z nim. Aktualizacje, które rozbijają wtyczki. Wtyczki, które ciągną kilkadziesiąt requestów na pageload. Hosting za 30–50 złotych miesięcznie, który i tak ledwo daje radę obsłużyć ruch z Google Discover. Bot SEO, który crawluje wp-admin zamiast Twoich treści. I ten moment, kiedy o drugiej w nocy dostajesz maila, że ktoś próbuje brute-force'ować panel logowania.

Przez ostatni rok zbudowałem od zera ponad piętnaście stron internetowych w zupełnie innym stosie technologicznym. Bez bazy danych. Bez serwera. Bez panelu logowania. Z Lighthouse Performance 95–100 i rachunkiem za hosting poniżej jednego dolara miesięcznie.

To nie jest teoretyczny artykuł o zaletach static site generation. To case study z konkretnymi projektami, liczbami, błędami i wnioskami.

## Co dokładnie buduję i dla kogo

Moje portfolio statycznych stron w Astro obejmuje kilkanaście produkcyjnych projektów w trzech głównych kategoriach.

Pierwsza to strony firmowe i portfolio dla klientów — meble-bydgoszcz.pl (producent mebli na wymiar w Bydgoszczy), by-interior.pl (studio projektowania wnętrz), nadamel.pl (usługi stolarskie: oklejanie, cięcie płyt, fronty meblowe), project-design.pl (firma projektowa). Każda z nich to wielopodstronowa witryna z galerią realizacji, opisami usług, formularzem kontaktowym i pełnym pakietem SEO.

Druga kategoria to portale edukacyjne i blogi contentowe — licencjackie.pl, praca-magisterska.pl, magisterkaonline.com.pl (portale z poradnikami dla studentów, łącznie ponad 60 artykułów), copywritingseo.pl (blog, na którym to czytasz), copywriting-blog.pl, 1copywriting.pl, ecopywriting.pl, agencja-copywriterska.pl.

Trzecia to strony zapleczowe i satelickie — silnik-elektryczny.pl i silniki-trojfazowe.pl (strony tematyczne wspierające sklep silniki-elektryczne.com.pl), sklad-tekstu.pl (strona usługowa mojej firmy składu tekstu w LaTeX).

Każda z tych stron działa na identycznym stosie: Astro SSG + Tailwind CSS + TypeScript, hostowana na AWS S3 z CloudFront CDN, Route 53 DNS i certyfikatami SSL z ACM.

## Stack technologiczny — dlaczego akurat ten

### Astro — zero JavaScriptu by default

Astro to framework, który odwraca filozofię budowania stron. Zamiast ładować framework JavaScript i potem próbować go optymalizować, Astro generuje czysty HTML i w ogóle nie wysyła JavaScriptu do przeglądarki — chyba że wyraźnie tego zażądasz.

W praktyce oznacza to, że moje strony mają zero kilobajtów JavaScript runtime. Porównaj to z typową stroną WordPress (200–800 KB JS) albo Next.js SSR (100–400 KB JS po hydracji). Googlebot widzi gotowy HTML natychmiast, bez czekania na renderowanie.

Tam, gdzie interaktywność jest potrzebna — formularz kontaktowy z walidacją, galeria ze sliderem, banner cookie consent z logiką Google Consent Mode v2 — używam tak zwanej Islands Architecture. Astro ładuje React tylko do tych konkretnych komponentów, a reszta strony zostaje czystym HTML.

### Tailwind CSS — utility-first bez nadmiarowego CSS

Każdy projekt używa Tailwind, co daje trzy korzyści: nie piszę ani jednej linijki martwego CSS, mam spójny design system (spacing, kolory, typografia), a po buildzie Tailwind tree-shake'uje nieużywane klasy i zostawia kilkanaście kilobajtów skompresowanego CSS.

### TypeScript — bezpieczeństwo na etapie buildu

Content Collections w Astro używają walidacji Zod. Jeśli zapomniałem dodać `description` w frontmatter artykułu albo wpisałem złą kategorię — build nie przejdzie. Błąd wyłapuję na moim komputerze, nie na produkcji.

### AWS S3 + CloudFront — CDN z 225+ edge locations

Pliki statyczne lądują na S3, a CloudFront cachuje je w ponad 225 lokalizacjach na świecie. Użytkownik z Gdańska, Krakowa i Londynu dostaje stronę z najbliższego edge'a. Nie ma serwera, który mógłby się przeciążyć. Nie ma bazy danych, która mogłaby paść. Nie ma PHP, które mogłoby mieć lukę bezpieczeństwa.

## Jak wygląda budowa strony — krok po kroku

Cały proces od pustego folderu do działającej strony na produkcji zajmuje mi od 4 do 12 godzin, w zależności od złożoności projektu.

### Inicjalizacja i struktura

Każdy projekt ma identyczną strukturę katalogów:

- `src/components/` — reużywalne komponenty Astro: Header, Footer, CookieBanner, PostCard, Breadcrumbs, AuthorBox, Newsletter, SEO
- `src/layouts/` — BaseLayout z pełnym zestawem meta tagów i JSON-LD, BlogPost z Article schema
- `src/pages/` — routing oparty na plikach, dynamiczne trasy `[slug].astro`
- `src/content/` — Content Collections z konfiguracją Zod
- `src/styles/` — globalny CSS z custom properties
- `src/utils/` — helpery: formatDate, readingTime, slugify, stałe strony

Takie podejście sprawia, że nowy projekt to kwestia skopiowania struktury i dostosowania treści, kolorystyki i komponentów specyficznych dla klienta. Nie buduję każdej strony od zera — buduję na sprawdzonym fundamencie.

### SEO — nie wtyczka, tylko architektura

W WordPress SEO to wtyczka — Yoast albo Rank Math, która generuje meta tagi. W Astro SEO to architektura całej strony.

W BaseLayout każdej strony mam zdefiniowane: canonical URL, pełne Open Graph (type, title, description, image, locale, site_name), Twitter Card z summary_large_image, JSON-LD z Organization i WebSite schema, hreflang, link do sitemap i RSS, a także preconnect do Google Fonts.

Dla stron blogowych BlogPost layout dodaje: Article schema z datePublished, dateModified, author i image, BreadcrumbList schema (breadcrumbs widoczne w SERP), Person schema dla E-E-A-T, pasek postępu czytania i sekcję powiązanych artykułów.

Dla stron usługowych: Service schema, FAQPage schema (z pytaniami, które mogą pojawić się jako rich results w Google).

Wszystko to jest renderowane w HTML na etapie buildu. Googlebot dostaje gotowy, poprawny JSON-LD bez konieczności renderowania JavaScriptu.

### Content Collections — Markdown na sterydach

Artykuły piszę w czystym Markdown z frontmatter walidowanym przez Zod:

```yaml
title: "E-E-A-T w praktyce — jak budować wiarygodność treści"
description: "Praktyczny przewodnik po E-E-A-T..."
pubDate: 2026-02-28
category: "podstawy-seo"
tags: ["eeat", "google", "wiarygodność"]
author: "Karol Leszczyński"
```

Dodanie nowego artykułu to dodanie pliku `.md` do folderu `src/content/blog/`. Astro automatycznie generuje stronę na podstawie pliku, dodaje ją do sitemap, RSS feed i indeksu bloga. Nie klikam w żaden panel. Nie loguję się do CMSa.

### Cookie Consent — nie byle jak

Każda moja strona ma GDPR-compliant cookie banner z Google Consent Mode v2. Domyślnie wszystkie zgody są ustawione na `denied`. GTM ładuje się warunkowo — dopiero po udzieleniu zgody przeglądarka wysyła pierwszy request do Google. Nie ma hardkodowanego `<noscript>` iframe GTM, który w wielu implementacjach wysyła request niezależnie od zgody.

To detal, ale właśnie takie detale odróżniają stronę zbudowaną przez kogoś, kto rozumie GDPR, od strony, gdzie ktoś wkleił snippet z tutoriala.

## Infrastruktura AWS — to, czego nie widać

Konfiguracja AWS to jeden z większych progów wejścia w tym workflow. Ale raz ustawiona infrastruktura działa praktycznie w nieskończoność bez interwencji.

### Co ustawiam dla każdej domeny

Dla każdego projektu tworzę: S3 bucket (prywatny, pliki dostępne tylko przez CloudFront), CloudFront distribution z Origin Access Control (HTTPS, custom domain, przekierowanie z apex na www), ACM certificate w regionie us-east-1 (wildcard `*.domena.pl`, walidacja DNS), Route 53 hosted zone z rekordami A/AAAA alias do CloudFront oraz rekordami poczty (MX, SPF, DKIM).

Opcjonalnie, jeśli strona ma formularz kontaktowy — Lambda function z integracją SES (wysyłka maili) i S3 presigned URLs (dla załączników). Serverless, zero kosztów stałych.

### Koszty — twarde dane

Prowadzę kilkanaście stron na tym stosie od ponad roku. Na podstawie rachunków AWS:

Route 53 hosted zone to stały koszt 0,50 USD/mies per domena. CloudFront i S3 to łącznie około 0,10–0,40 USD/mies per strona przy normalnym ruchu (500–2000 wizyt miesięcznie). ACM certyfikaty są darmowe. Lambda — przy wolumenie formularzy kontaktowych mieści się w free tier, efektywny koszt to zero.

Łączny koszt jednej strony to mniej niż 1 USD miesięcznie. Przy piętnastu stronach płacę tyle, ile WordPress kosztowałby na jednym VPS — z tą różnicą, że moje piętnaście stron nie ma żadnych problemów z bezpieczeństwem, aktualizacjami ani wydajnością.

### Deploy — 60 sekund od commita do produkcji

Standardowy deploy to trzy komendy:

```bash
npm run build          # Generowanie statycznych plików
aws s3 sync dist/ s3://bucket --delete   # Upload na S3
aws cloudfront create-invalidation --paths "/*"   # Cache flush
```

Dla wielu stron mam to zautomatyzowane — GitHub Actions lub AWS CodeBuild z webhookiem. Push do repozytorium triggeruje automatyczny rebuild i deploy. Strony satelickie silnik-elektryczny.pl i silniki-trojfazowe.pl mają pełny pipeline: EventBridge + Lambda + CodeBuild, który przebudowuje stronę automatycznie po zmianach w głównym sklepie.

## Błędy, które popełniłem — i Ty popełnisz

Nie byłoby uczciwe opisywać tylko sukcesów. Oto problemy, na które się natknąłem:

**Deploy na zły bucket S3.** Miałem dwa buckety dla meble-bydgoszcz — jeden ze starej konfiguracji, jeden nowy. Pół godziny debugowania, zanim sprawdziłem, który bucket jest podpięty do dystrybucji CloudFront. Lekcja: zawsze weryfikuj komendą `aws cloudfront get-distribution --query Origins`.

**Stara wersja strony po deployu.** CloudFront cache jest agresywny. Bez invalidacji użytkownicy widzą starą wersję nawet po uploadzieleniu nowych plików. Invalidacja `--paths "/*"` musi być częścią każdego deploy skryptu.

**Certyfikat SSL nie działa.** ACM certificate dla CloudFront musi być w regionie us-east-1, niezależnie od tego, gdzie jest S3 bucket. Przeoczyłem to przy pierwszym projekcie i straciłem godzinę.

**Poczta przestała działać po migracji DNS.** Przenosząc domenę na Route 53, zapomniałem przenieść rekordy MX, SPF i DKIM. Poczta klienta leżała przez kilka godzin. Teraz mam checklistę: przed migracją DNS eksportuję wszystkie istniejące rekordy.

**404 na podstronach z trailing slash.** CloudFront nie wie, że `/uslugi/` powinno serwować `/uslugi/index.html`. Rozwiązanie: CloudFront Function, która rewrituje URI, dodając `index.html` do ścieżek kończących się na `/`.

Każdy z tych błędów kosztował mnie czas, ale też dał wiedzę, której nie da się zdobyć z tutoriala.

## Core Web Vitals — dlaczego to ma znaczenie

Google od 2021 roku oficjalnie włączył Core Web Vitals do algorytmu rankingowego. Trzy metryki — LCP, INP i CLS — decydują o tym, czy Twoja strona ma przewagę w wynikach wyszukiwania.

Moje strony Astro SSG naturalnie osiągają wyniki, o których strony WordPress mogą pomarzyć: LCP poniżej jednej sekundy (cel Google: poniżej 2,5 s), INP poniżej 50 milisekund (cel: poniżej 200 ms, przy czym bez JavaScriptu nie ma co mierzyć), CLS równe zero (statyczny layout, żadne elementy nie przesuwają się po załadowaniu).

Efekt końcowy to Lighthouse Performance 95–100 i Accessibility 100 na każdej stronie, zaraz po wdrożeniu, bez dodatkowej optymalizacji. Cel deklarowany w README meble-bydgoszcz.pl to „95+ na wszystkich metrykach" — i jest on realizowany konsekwentnie.

## Kiedy ten stos nie działa

Będę uczciwy: Astro SSG nie jest odpowiedzią na wszystko.

Sklep internetowy silniki-elektryczne.com.pl — z koszykiem, dynamicznymi cenami, stanami magazynowymi, integracją z Allegro i Google Merchant Center — działa na Astro, ale w trybie SSR z Node adapter. To zupełnie inny tryb pracy niż statyczna generacja, z własnym serwerem EC2 i backendem Fastify. Astro SSG nie obsłuży dynamicznego e-commerce.

Aplikacje SaaS (Smart-Copy.ai, Smart-Edu.ai, MaturaPolski.pl) działają na React + Fastify + PostgreSQL. Panel administracyjny, autentykacja, real-time — to nie jest domena generatorów stron statycznych.

Ale dla stron firmowych, blogów, portali edukacyjnych, landing pages usługowych i stron zapleczowych SEO — Astro SSG na AWS to najefektywniejsze rozwiązanie, jakie znam.

## Strony zapleczowe — słoń w pokoju

Jedna z najmniej omawianych publicznie korzyści Astro SSG to budowanie stron zapleczowych dla pozycjonowania. Opiszę to wprost.

Strona zapleczowa (satellite site) to domena tematycznie powiązana z główną stroną, budująca dodatkowy profil linkowy i topical authority. Kluczowe: to nie jest PBN (Private Blog Network). PBN to sieć stron tworzonych wyłącznie dla manipulacji linkami, z thin content i generycznym wyglądem. Google wykrywa PBN z coraz większą precyzją dzięki SpamBrain.

Moje strony zapleczowe to pełnoprawne witryny z oryginalną, merytoryczną treścią, indywidualnym designem i realną wartością dla użytkownika. Test, który stosuję: „Czy ta strona miałaby sens, gdyby nie generowała żadnej korzyści SEO?" Jeśli odpowiedź brzmi tak — to legalna strona satelicka. Jeśli nie — to PBN.

Dlaczego Astro jest w tym kontekście idealne? Po pierwsze, brak footprintu technologicznego. WordPress na współdzielonym hostingu dzieli IP, strukturę wp-content, te same motywy i wtyczki. Strona Astro na CDN to unikalny HTML na losowym IP CloudFront — nie ma żadnych wspólnych elementów z innymi stronami.

Po drugie, perfekcyjne Core Web Vitals. Strona z Lighthouse 98 wygląda jak profesjonalna witryna, nie jak szybko postawiony blog na darmowym szablonie.

Po trzecie, koszt. Prowadzenie dziesięciu stron zapleczowych na AWS kosztuje mnie mniej niż jeden shared hosting z WordPress.

## Skalowanie — co dalej

Przy piętnastu stronach zaczynają pojawiać się wyzwania organizacyjne. Każda nowa domena wymaga ręcznej konfiguracji AWS (S3, CloudFront, ACM, Route 53). Aktualizacja treści wymaga commita i deployu.

Kierunki, nad którymi pracuję: Terraform do automatyzacji infrastruktury — nowa domena to `terraform apply` zamiast trzydziestu minut klikania w konsoli AWS. Multi-tenant CMS — jeden panel do zarządzania treścią wielu stron z webhookiem triggerującym rebuild per klient. Ujednolicony pipeline CI/CD — jeden workflow GitHub Actions parametryzowany nazwą domeny.

## Podsumowanie — czy warto

Jeśli budujesz strony firmowe, blogi, portale contentowe albo strony usługowe — Astro SSG na AWS to technologia, która daje przewagę na każdym froncie: szybkość (2–3 razy szybciej niż Next.js dla content sites), koszt (mniej niż 1 USD/mies per strona), bezpieczeństwo (zero surface attack), SEO (pełna kontrola nad każdym elementem HTML) i skalowalność (CloudFront CDN obsłuży dowolny ruch).

Próg wejścia jest wyższy niż „zainstaluj WordPress i motyw". Musisz umieć pisać w Markdown, rozumieć HTML/CSS, konfigurować AWS CLI i nie bać się terminala. Ale efekt to strona, która działa szybciej, kosztuje mniej i nie wymaga żadnego utrzymania serwerowego.

Po roku produkcji z tym stosem nie widzę powodu, żeby wracać do WordPress dla jakiegokolwiek projektu contentowego.

Chcesz zobaczyć, jak to wygląda w praktyce? Strona, którą właśnie czytasz — copywritingseo.pl — działa dokładnie na tym stosie.
