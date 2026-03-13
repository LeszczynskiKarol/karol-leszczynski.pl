---
title: "Jak obsługuję 30+ domen na AWS za ~$117 miesięcznie — praktyczny przewodnik po infrastrukturze"
description: "Pełny przegląd infrastruktury AWS obsługującej ponad 30 domen: strony statyczne Astro na S3 + CloudFront, aplikacje na EC2 z PM2 i nginx, Lambda, CodeBuild, SES. Z prawdziwymi kosztami, komendami CLI i lekcjami z produkcji."
pubDate: 2026-03-13
heroImage: "/images/blog/aws-infrastructure-map.jpg"
heroImageAlt: "Schemat infrastruktury AWS z S3, CloudFront, EC2, Lambda i CodeBuild"
category: "seo-techniczne"
tags:
  [
    "aws",
    "s3",
    "cloudfront",
    "ec2",
    "lambda",
    "infrastruktura",
    "devops",
    "case study",
    "astro",
  ]
draft: false
author: "Karol Leszczyński"
pillar: false
relatedPosts: ["jak-zbudowalem-15-stron-astro-aws-case-study"]
---

Zarządzam ponad 30 domenami na AWS. Strony statyczne, aplikacje SaaS, sklep e-commerce, scraper AI, satelity SEO z auto-rebuildem. Całość kosztuje mnie około 117 dolarów miesięcznie (bez podatku). Nie mam zespołu DevOps. Nie używam Kubernetes. Nie mam Terraform (jeszcze). Zarządzam tym z terminala, przez AWS CLI i SSH.

Ten artykuł to praktyczny przegląd mojej infrastruktury — z prawdziwymi kosztami, prawdziwymi komendami i prawdziwymi problemami, które napotkałem po drodze.

## Architektura — trzy warstwy, jedno konto AWS

Moja infrastruktura dzieli się na trzy warstwy, z których każda obsługuje inny typ projektu.

Pierwsza warstwa to strony statyczne. Astro SSG buduje HTML, CSS i JS. Pliki trafiają na S3, CloudFront dystrybuuje je globalnie, ACM zapewnia SSL, Route 53 zarządza DNS. Koszt: praktycznie zero — CloudFront kosztował mnie w lutym 2026 dosłownie $0.00006. Sześć setnych centa.

Druga warstwa to aplikacje dynamiczne. Cztery instancje EC2 t3.small. Na każdej instancji kilka aplikacji, zarządzanych przez PM2 i nginx. PostgreSQL działa lokalnie na instancjach (nie RDS — za drogi na moją skalę).

Trzecia warstwa to serverless dla stron statycznych Astro. Lambda do formularzy kontaktowych, presigned URLs, edge redirects i API proxy dla satelitów e-commerce. CodeBuild z EventBridge do automatycznych rebuildów stron satelickich co 30 minut.

## Strony statyczne — S3 + CloudFront + ACM + Route 53

Na moim koncie AWS jest ponad 90 bucketów S3. Znaczna część to pary: `domena.pl` (redirect na www) i `www.domena.pl` (właściwy content). Do tego buckety na załączniki, ebooki, deploy paczki Lambda i pliki użytkowników.

Każda statyczna strona ma ten sam wzorzec infrastruktury. S3 bucket skonfigurowany jako static website hosting z `index.html` jako domyślnym dokumentem. CloudFront distribution z origin wskazującym na S3 website endpoint (nie na S3 REST API — to ważna różnica, bo website endpoint obsługuje routing i error pages). Certyfikat SSL z ACM w regionie us-east-1 (CloudFront wymaga tego regionu, niezależnie gdzie jest bucket). Route 53 hosted zone z rekordami A/AAAA typu alias wskazującymi na CloudFront.

Aktualnie mam 51 dystrybucji CloudFront. Większość używa `PriceClass_100` (najtańsza — Europa, Ameryka Północna, Izrael). Kilka kluczowych domen (karol-leszczynski.pl, meble-bydgoszcz.pl, silniki-trojfazowe.pl) ma `PriceClass_All` — globalny zasięg, bo testowałem różne konfiguracje. W praktyce dla polskich stron `PriceClass_100` wystarczy.

![51 dystrybucji CloudFront — widok z konsoli AWS](/dystrybucje_cloudfront.jpg)

Każda dystrybucja ma włączoną kompresję (`Compress: true`) i wymuszony HTTPS (`redirect-to-https`). Default root object to `index.html`. Te trzy ustawienia — kompresja, HTTPS, default root — są obowiązkowe. Bez nich albo strona nie zadziała, albo Google obniży ranking.

Mam 27 certyfikatów SSL w ACM — wszystkie `AMAZON_ISSUED` z automatycznym odnawianiem przez walidację DNS. Jeden (smart-edu.ai) wygasł, bo domena była tymczasowo odłączona. Reszta odnawia się sama bez interwencji.

31 hosted zones w Route 53 — każda domena to osobna zona. Łączna liczba rekordów DNS to ponad 300. Route 53 to akurat mój najdroższy serwis po EC2. Każda hosted zone kosztuje $0.50/miesiąc, więc 31 zon × $0.50 = $15.50. Do tego dochodzą koszty zapytań DNS. Przy 30+ domenach to się kumuluje.

![31 hosted zones w Route 53 — każda domena to osobna zona DNS](/widok_hosted_zones.jpg)

### Wzorzec deployu strony statycznej

Każda statyczna strona deployuje się identycznie. Astro buduje katalog `dist/`. Zawartość synchronizuję z S3 poleceniem `aws s3 sync`. Po synchronizacji invaliduję cache CloudFront. Cały deploy trwa 30–60 sekund.

Trzy komendy — tyle potrzeba, żeby zdeployować stronę Astro na AWS:

```bash
# Deploy statycznej strony Astro — 3 komendy
npm run build

aws s3 sync dist/ s3://www.copywritingseo.pl \
  --delete \
  --cache-control "public, max-age=31536000"

aws cloudfront create-invalidation \
  --distribution-id E2XKLUITT2JYBM \
  --paths "/*"
```

Dla satelitów e-commerce (silnik-elektryczny.pl, silniki-trojfazowe.pl) deploy jest zautomatyzowany. CodeBuild pobiera source z bucketu S3, instaluje zależności, buduje stronę i synchronizuje output. EventBridge triggeruje build co 30 minut. Osobna Lambda (`silnik-elektryczny-rebuild`) może też triggerować build na żądanie — np. po zmianie stocku w sklepie.

Cały plik `buildspec.yml` — CodeBuild wie, co robić:

```yaml
# buildspec.yml — silniki-trojfazowe-pl
version: 0.2
phases:
  install:
    commands:
      - npm ci
  build:
    commands:
      - npm run build
  post_build:
    commands:
      - aws s3 sync dist/ s3://www.silniki-trojfazowe.pl --delete
      - aws cloudfront create-invalidation
        --distribution-id E2Q8CBRHCSGB32 --paths "/*"
cache:
  paths:
    - "node_modules/**/*"
```

## Instancje EC2 — cztery serwery, osiem aplikacji

Nie używam kontenerów ani orkiestratorów. Każda instancja to Ubuntu 22.04 z Node.js, PM2, nginx i (opcjonalnie) PostgreSQL. PM2 zarządza procesami — restartuje je po crashu, loguje stdout/stderr, daje monitoring przez `pm2 list`. Nginx robi reverse proxy z TLS termination — każda domena ma osobny `server` block wskazujący na lokalny port.

### Instancja 1: MaturaPolski + Interpunkcja + Copywriting24

Ta instancja t3.small obsługuje trzy aplikacje edukacyjne. MaturaPolski to platforma do nauki literatury z AI — działa w trybie cluster na PM2, zajmuje 134 MB RAM. Interpunkcja.com.pl to SaaS do sprawdzania polskiej pisowni — 96 MB. Copywriting24.pl to mniejszy projekt — 90 MB.

Nginx obsługuje 3 domeny: maturapolski.pl, interpunkcja.com.pl i copywriting24.pl — każda z wariantem www. Stan z 13 marca 2026: dysk 36% zajęty (11 GB z 29 GB), RAM 32% (508 MB z 1.9 GB), swap praktycznie pusty. Uptime 18 dni.

### Instancja 2: Smart-Copy + Smart-Edu + panel.torweb

Tutaj siedzą cięższe aplikacje AI. Smart-Edu (backend Fastify + Prisma + Claude API) zajmuje 152 MB RAM — to moja najbardziej zasobożerna apka. Smart-Copy backend zajmuje tylko 27 MB (lekki). Nginx obsługuje pięć domen: smart-copy.ai (z en. subdomeną), smart-edu.ai i panel.torweb.pl.

Stan: dysk 54% (16 GB z 29 GB — gorzej, bo logi i dane użytkowników), RAM 39% (623 MB), swap 22% zajęty (451 MB z 2 GB). Ten swap na 22% oznacza, że przy peakach pamięci system zrzuca część danych na dysk. Nie jest to idealne, ale t3.small z 2 GB RAM to limit dla dwóch apek AI. Alternatywa — t3.medium za dwukrotnie wyższą cenę — na razie nie jest uzasadniona.

### Instancja 3: Stojan — sklep e-commerce

Specjalna nstancja dla <a href="https://www.silniki-elektryczne.com.pl">silniki-elektryczne.com.pl</a>. Dwa procesy PM2: backend Fastify z Prisma (225 MB RAM — najcięższy ze wszystkich, bo trzyma w pamięci cache produktów i sesje Allegro) i frontend Astro SSR (91 MB).

PostgreSQL z bazą `stojan_shop_new` działa lokalnie — nie na RDS. RDS db.t3.micro kosztowałby ~$15/miesiąc. PostgreSQL na tej samej instancji kosztuje $0. Przy jednym sklepie z kilkuset produktami i kilku zamówieniach dziennie to wystarczające — backup robię przez `pg_dump` do S3. Nginx obsługuje dwie domeny: silniki-elektryczne.com.pl i api.silniki-elektryczne.com.pl. Stan: dysk 61% (13 GB z 20 GB), RAM 30% (581 MB z 1.9 GB), uptime 80 dni.

### Instancja 4: Scraper AI (Elastic Beanstalk)

Jedyna instancja, która nie używa PM2. To aplikacja Python 3.9 na Gunicorn, wdrożona przez Elastic Beanstalk. Służy jako centralny scraper — pobiera treści ze stron WWW na potrzeby pipeline'ów AI w MaturaPolski, Smart-Edu i Smart-Copy (research do generowania artykułów, źródła do prac naukowych).

Pod spodem działa 4 instancji ChromeDriver (widać na portach 36639, 53989, 55867, 56767) — headless Chrome do renderowania stron z JavaScript. Gunicorn obsługuje requesty HTTP na porcie 8000, nginx proxy na 80. Stan: dysk 54% (4.3 GB z 8 GB — mały wolumen, bo scraper nie przechowuje danych długoterminowo), RAM 24% (468 MB), zero swap (bo nie jest skonfigurowany). Uptime 101 dni — najdłuższy ze wszystkich instancji.

## Lambda — serverless tam, gdzie ma sens

17 funkcji Lambda w dwóch regionach. Większość to para: `contact` (formularz kontaktowy wysyłający email przez SES) i `presign` (generowanie presigned URL do uploadu plików na S3). Wzorzec powtarza się per domena.

Formularze kontaktowe: `contact-form-handler`, `ecopywriting-contact`, `icopywriter-contact`, `nadamel-contact`, `sklad-tekstu-contact`, `agencja-copywriterska-contact`. Każdy to ~50 linii Node.js — waliduje dane, wysyła email przez SES, zwraca odpowiedź. Timeout 15 sekund, 128 MB RAM.

Presigned URLs: `ecopywriting-presign`, `icopywriter-presign`, `nadamel-presign`, `sklad-tekstu-presign`, `agencja-copywriterska-presign`. Generują tymczasowy URL do bezpośredniego uploadu pliku na S3 z przeglądarki, omijając backend.

Specjalne: `silnik-elektryczny-rebuild` (512 MB RAM, triggeruje CodeBuild), `silnik-elektryczny-api` (Lambda proxy do API sklepu dla stron satelickich), `redirect-to-www` i `redirect-to-www-edge` (Lambda@Edge do wymuszania www).

W regionie us-east-1 dodatkowo: `emailstojan` (powiadomienia o zamówieniach), `EmailForwarder` (Python — forwarding emaili między domenami).

Koszt Lambda w lutym: $0.0000116. Dosłownie — ułamek centa. Free tier pokrywa praktycznie całe moje użycie.

## CodeBuild — automatyczny rebuild satelitów

Dwa projekty CodeBuild w Sztokholmie: `silnik-elektryczny-pl` i `silniki-trojfazowe-pl`. Oba budują strony satelickie e-commerce, które wyświetlają produkty ze sklepu Stojan.

Konfiguracja: source z S3 (bucket z kodem Astro), obraz `amazonlinux2-x86_64-standard:5.0`, typ `BUILD_GENERAL1_SMALL`, timeout 10 minut. W praktyce build trwa 40–90 sekund.

EventBridge ma jedną aktywną regułę: `silnik-elektryczny-pl-rebuild-cron` z interwałem `rate(30 minutes)`. Co 30 minut strona satelicka przebudowuje się z aktualnym stanem magazynowym ze sklepu. Jeśli silnik został sprzedany — znika ze strony satelickiej w ciągu pół godziny.

Koszt CodeBuild: w granicach free tier. AWS daje 100 minut/miesiąc za darmo. Przy 48 buildach dziennie × 1.5 minuty = 72 minuty/dzień to przekraczam free tier, ale koszt dodatkowych minut jest minimalny.

## SES — email

16 zweryfikowanych tożsamości w SES: domeny (silniki-elektryczne.com.pl, ecopywriting.pl, copywritingseo.pl, mekra.pl, i inne) plus kilka konkretnych adresów (sklep@ebookcopywriting.pl, kontakt@sklad-tekstu.pl). SES służy do: wysyłki kodów rejestracyjnych, potwierdzeń zamówień w sklepie, powiadomień administracyjnych, formularzy kontaktowych z Lambda, i forwarding emaili. Od stycznia 2026 SES kosztuje $0.002/miesiąc.

## Koszty — prawdziwe liczby z Cost Explorer

Łączny rachunek za luty 2026 wyniósł $144.54 (w tym $27.03 podatku VAT). Bez podatku: $117.51. To jest koszt obsługi ponad 25 domen, czterech instancji EC2, ponad 90 bucketów S3, 51 dystrybucji CloudFront i 17 funkcji Lambda.

![Rozkład kosztów AWS per serwis — luty 2026](/rozklad_kosztow_per_service_aws_luty_2026_graph.jpg)

Podział kosztów za luty 2026 wygląda następująco. EC2 Compute (cztery instancje t3.small 24/7) to $77.95 — zdecydowanie największy koszt, stanowiący 66% rachunku. VPC (Elastic IP, transfer między strefami) to $15.47. Route 53 (31 hosted zones + zapytania DNS) to $13.12. EC2 Other (wolumeny EBS, snapshoty) to $9.15. Reszta serwisów to ułamki dolara: S3 za $0.67, GuardDuty za $0.75, Secrets Manager za $0.40, CloudFront, Lambda, API Gateway i SES — łącznie poniżej centa.

## Jak deployuję nową statyczną stronę — krok po kroku

Kiedy klient potrzebuje nowej strony, powtarzam ten sam zestaw kroków. Cały proces zajmuje 15–20 minut.

Najpierw tworzę dwa buckety S3: `domena.pl` (redirect na www) i `www.domena.pl` (content). Konfiguruję static website hosting na obu. Ustawiam bucket policy pozwalającą na publiczny odczyt. Następnie tworzę certyfikat SSL w ACM (region us-east-1) z walidacją DNS — dodaję rekord CNAME do Route 53, certyfikat waliduje się w 5–15 minut. Tworzę dwie dystrybucje CloudFront: jedną na www (główna), drugą na naked domain (redirect). Tworzę hosted zone w Route 53, ustawiam rekordy A/AAAA alias na CloudFront. Na końcu aktualizuję nameservery u registrara na te z Route 53.

Jeśli strona potrzebuje formularza kontaktowego — dodaję Lambda z API Gateway. Template mam gotowy, zmieniam tylko adres docelowy emaila i nazwę domeny w CORS.

## Cztery instancje, osiem aplikacji, zero DevOps

Nie mam CI/CD w tradycyjnym sensie. Deploy na EC2 to `git pull` + `npm run build` + `pm2 restart`. Załatwiam to jednym skryptem shell. PM2 daje mi: automatyczny restart po crashu, logi per proces (`pm2 logs nazwa`), monitoring (`pm2 monit`), startup script (procesy startują po reboocie). Nginx daje mi: TLS termination, reverse proxy per domena, rate limiting, gzip compression. Razem — wystarczające dla mojej skali.

Jedyna automatyzacja, której naprawdę potrzebuję (i mam), to CodeBuild + EventBridge dla satelitów e-commerce. Reszta deployów jest na tyle rzadka (raz na kilka dni, nie kilka razy dziennie), że ręczne uruchomienie skryptu shell jest szybsze niż setup pipeline'u.

Tak wygląda produkcyjna instancja Stojan — `pm2 list` prosto z terminala:

```bash
# pm2 list — instancja Stojan (16.171.6.205)
┌────┬────────────────────┬──────┬──────┬───────────┬──────────┬──────────┐
│ id │ name               │ mode │ ↺    │ status    │ cpu      │ memory   │
├────┼────────────────────┼──────┼──────┼───────────┼──────────┼──────────┤
│ 0  │ stojan-backend     │ fork │ 32   │ online    │ 0%       │ 225.2mb  │
│ 1  │ stojan-frontend    │ fork │ 32   │ online    │ 0%       │ 90.5mb   │
└────┴────────────────────┴──────┴──────┴───────────┴──────────┴──────────┘

# nginx — domeny na tej instancji
server_name api.silniki-elektryczne.com.pl;
server_name silniki-elektryczne.com.pl www.silniki-elektryczne.com.pl;

# PostgreSQL
stojan_shop_new | postgres | UTF8 | C.UTF-8

# Uptime: 80 days, RAM: 581Mi/1.9Gi, Disk: 61%
```

## Czego się nauczyłem po roku na AWS

CloudFront jest praktycznie darmowy dla statycznych stron w Polsce. Przy polskim ruchu (kilkaset–kilka tysięcy pageviews dziennie) koszt wynosi ułamki centa miesięcznie. Nie ma powodu, żeby nie używać CDN.

Route 53 jest droższy, niż myślisz. $0.50 za hosted zone wygląda niewinnie, ale przy 31 zonach to $15.50/mies. tylko za sam fakt istnienia zon, bez żadnego ruchu. Przy wielu domenach warto rozważyć Cloudflare DNS (darmowy) z CNAME na CloudFront.

t3.small z 2 GB RAM wystarczy na 2-3 lekkie aplikacje Node.js. Przy cięższych apkach (AI pipeline, scraping) zaczyna swapować. Próg komfortu to ~1.2 GB zajętego RAM — powyżej tego system zaczyna używać swap i response time rośnie.

PostgreSQL na tej samej instancji co aplikacja to kontrowersyjna decyzja, ale przy niskim ruchu — uzasadniona. RDS db.t3.micro kosztuje ~$15/mies. za samą bazę danych. Lokalny PostgreSQL kosztuje $0. Kompromis: robię backup przez `pg_dump` na S3 raz dziennie. Gdyby instancja padła, tracę maksymalnie jeden dzień danych.

## Kiedy ten setup ma sens

Moja infrastruktura ma sens, kiedy: zarządzasz wieloma niszowymi domenami (SEO, portfolio, klienci), ruch jest umiarkowany (setki–tysiące PV/dziennie, nie miliony), masz wiedzę techniczną, ale nie masz zespołu DevOps, i zależy Ci na pełnej kontroli nad kosztami.

Nie ma sensu, kiedy: potrzebujesz auto-scalingu (EC2 fixed-size tego nie daje), masz zespół programistów, który potrzebuje CI/CD i staging environments, albo wolisz managed services i jesteś gotów za nie płacić (Vercel, Netlify, Railway).

Mój setup to kompromis między kontrolą a wygodą. Płacę mniej, ale robię więcej ręcznie. Dla jednej osoby zarządzającej 30+ domenami — ten kompromis się opłaca.
