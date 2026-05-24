---
title: "Jak zbudowałem matury-online.pl — od statycznego SEO do pełnego SaaS w pół roku"
description: "Case study budowy platformy do nauki do matury z polskiego: Astro frontend, Node + Postgres backend na EC2, AI do oceny wypracowań według kryteriów CKE. Konkretne decyzje architektoniczne, koszty, błędy i wnioski z pierwszych miesięcy produkcji."
pubDate: 2026-05-22
category: "case-study"
tags:
  [
    "matura",
    "saas",
    "astro",
    "aws",
    "ec2",
    "postgres",
    "ai",
    "edukacja",
    "case study",
  ]
draft: false
author: "Karol Leszczyński"
---

Statyczne strony skończyły mi się na etapie poradników.

Po roku budowania kilkunastu witryn w Astro hostowanych na S3 + CloudFront miałem jasny obraz: dla treści SEO i landing page'y to świetna technologia, ale jak tylko pojawia się stan użytkownika — login, postęp w nauce, zapisywane wypracowania, ocena przez AI — czysty SSG przestaje wystarczać. Doszedłem do ściany.

[matury-online.pl](https://www.matury-online.pl) to mój pierwszy projekt, w którym zdecydowałem się przeskoczyć tę ścianę. To pełna platforma SaaS do przygotowania do matury z języka polskiego, z bazą zadań CKE, interaktywnymi arkuszami, ocenianiem wypracowań przez AI według oficjalnych kryteriów i symulacją egzaminu na żywo. Architektura jest hybrydowa: statyczny Astro tam, gdzie się da, dynamiczny backend tam, gdzie trzeba.

Ten tekst to konkretne case study — co zdecydowałem, dlaczego, co poszło dobrze, co źle, ile to wszystko kosztowało.

## Dlaczego w ogóle matura

Skąd pomysł na taki projekt — przy moim background'zie copywriterskim i web-developerskim?

Trzy obserwacje. Po pierwsze, zadania maturalne z polskiego są publicznie dostępne (arkusze CKE leżą w PDF-ach na stronie Centralnej Komisji Egzaminacyjnej), ale w formie absolutnie nieprzyjaznej do nauki — kilkanaście arkuszy rocznie, każdy w osobnym PDF-ie, bez wyszukiwania, bez tagowania po lekturach, bez sprawdzania odpowiedzi. Po drugie, generatywne AI jest wystarczająco dobre, żeby ocenić wypracowanie maturalne według kryteriów CKE (treść, kompozycja, język, ortografia) — i robi to spójnie, jeśli się dobrze przygotuje prompty. Po trzecie, polski rynek korepetycji z polskiego to setki milionów rocznie i prawie cały opiera się na human-in-the-loop. AI może obsłużyć dolny segment kosztowo absolutnie nie do pobicia.

Te trzy obserwacje razem dawały tezę produktową, w której uwierzyłem: jeśli zbuduję bazę przeszukiwalnych zadań CKE z dobrymi odpowiedziami i dodam ocenę wypracowań przez AI za parę złotych miesięcznie, znajdę użytkowników.

## Architektura — co statyczne, co dynamiczne

Cały frontend [matury-online.pl](https://www.matury-online.pl) jest w Astro. To samo, co używam do moich poradników. Różnica jest taka, że jest częściowo statyczny, częściowo dynamiczny.

Strony przedmiotowe (polski, matematyka, angielski itd.), strony lektur, baza zadań grupowana po lekturach, [archiwum arkuszy CKE 2002–2026](https://www.matury-online.pl/arkusze), wszystkie strony "informacyjne" (regulamin, polityka prywatności, blog, FAQ) — to czysty SSG. Pre-rendowany HTML, serwowany z CloudFront, Lighthouse 95–100. Bez różnicy względem moich statycznych poradników.

Co dynamiczne: panel użytkownika, postęp w nauce, [interaktywne rozwiązywanie zadań](https://www.matury-online.pl/zadania), wypracowania (zapis treści w bazie + endpoint do oceny przez AI), [symulacja egzaminu na żywo](https://www.matury-online.pl/egzamin), płatności Stripe. Te ścieżki obsługuje Node.js z Fastify, Postgres jako persystencja, Redis dla rate-limitingu i kolejki zadań do LLM.

Astro pięknie obsługuje ten miks. Strony statyczne są pre-rendowane w build-time, strony dynamiczne renderują się po stronie serwera w Node przy każdym requeście, a frontowe widgety (formularz wypracowania, edytor odpowiedzi, timer egzaminu) to React Islands ładowane tylko tam, gdzie są potrzebne. Reszta strony zostaje czystym HTML.

To nie jest fancy decyzja architektoniczna — to po prostu praktyczna. Najpierw porywam ruch SEO statycznymi stronami z bazy wiedzy. Potem część tego ruchu konwertuje się na rejestrację. Zarejestrowany użytkownik dostaje funkcje dynamiczne. Każda warstwa robi to, do czego się nadaje.

## Backend — dlaczego nie Lambda

Kuszący kierunek był serverless. Lambda + DynamoDB + Cognito. Skalowanie automatyczne, brak serwera do utrzymania, pay-per-request.

Wybrałem inaczej — pojedyncza instancja EC2 t3.medium z PostgreSQL i Redisem na tej samej maszynie, Fastify jako framework HTTP, PM2 jako process manager. Trzy powody.

**Po pierwsze, długie operacje LLM.** Ocena wypracowania przez Claude trwa 15–40 sekund. Lambda ma cold start, timeout 15 minut (OK), ale rozliczenie per millisekunda + utrzymanie połączenia dla streamingowych odpowiedzi staje się kłopotliwe. Na własnym Fastify trzymam streaming SSE prosto, bez gimnastyki.

**Po drugie, koszty.** Przy moim ruchu (kilkaset zapytań LLM dziennie + ruch HTTP z bazy zadań) EC2 t3.medium z RDS-em zastąpionym lokalnym Postgresem wychodzi taniej niż Lambda + DynamoDB + API Gateway. Konkretnie: ~30 USD/miesiąc za EC2 + EBS, ~15 USD za CloudFront i Route 53, plus to, co rzeczywiście wydaję na API Anthropica. Łącznie poniżej 100 USD przy obecnym ruchu, z czystym sumieniem na hardware reserves do skalowania.

**Po trzecie, deweloperskie tempo.** Mam jeden backend, jeden process manager, jedno miejsce do logów, jedna baza danych do migracji Prismą. Lokalnie `npm run dev` uruchamia wszystko. Deploy to `git pull && pm2 reload`. Cała komplikacja serverless zniknęła.

Trade-off jest taki, że jak instancja padnie, padnie cały serwis. Akceptuję to ryzyko na tym etapie — UptimeRobot pinguje co minutę, CloudWatch alarmy walą na maila, automatyczne snapshoty EBS co 24h. Strata danych ograniczona, downtime mierzony w minutach a nie godzinach. Kiedy przyjdzie skala, na której to przeszkadza, zmigruję — ale nie zaraz.

## AI do oceny wypracowań — to było najtrudniejsze

Założenie: użytkownik pisze wypracowanie maturalne, naciska "oceń", po 20 sekundach dostaje punktową ocenę według czterech kryteriów CKE (treść, kompozycja, język i styl, ortografia i interpunkcja) plus konkretny feedback co poprawić.

Co kombinowałem przez pierwsze miesiące:

**Pierwsza wersja: jeden duży prompt z całymi kryteriami.** Wynik losowy. Czasem 32/35 za przeciętny tekst, czasem 18/35 za dobry. Brak spójności między różnymi wywołaniami dla tego samego tekstu. Nie nadawało się do publikacji.

**Druga wersja: prompt podzielony na kryteria, każde oceniane osobno.** Spójność lepsza, ale dalej nieakceptowalna. Problem: model ocenia tekst inaczej w zależności od tego, co właśnie ocenił wcześniej w tym samym wywołaniu.

**Trzecia wersja, ta która została:** każde kryterium to osobny request z osobnym, ustrukturyzowanym promptem, z few-shot examples (po dwa przykłady tekstów z oceną CKE per kryterium), w trybie deterministycznym (temperature 0). Wyniki łączę po stronie backendu w finalną notę. Wariancja spadła do akceptowalnego poziomu — w testach na 50 wypracowaniach z wynikami CKE odchylenie standardowe było w okolicach 2 punktów na 35.

Czego się nauczyłem: do oceny edukacyjnej rozbijanie problemu na atomy + deterministyczne wywołania + few-shot z dobrze dobranymi przykładami to nie ozdoba, tylko warunek konieczny. Jedno wywołanie LLM nie jest klasyfikatorem — pięć wywołań w pipeline'ie już może być.

Jeśli interesuje cię ten temat głębiej, mam o nim osobny wpis — [jak budować pipeline wieloagentowy do generowania treści](/blog/multi-agent-ai-pipeline-do-generowania-tresci/). Architektura jest analogiczna.

## SEO — co działa, co nie

Strategiczna teza była taka: statyczne strony z bazy wiedzy łapią ruch, część konwertuje na rejestrację.

Stan dzisiaj (po ~5 miesiącach od startu): 4 wyświetlenia w GSC dla domeny głównej, pozycja 23. To jest nic. Konkurencyjność na frazy typu "matura polski" jest absurdalnie wysoka — bryk.pl, sciaga.pl, klp.pl, ściągi.com, opracowanie.pl, nazwa.pl ze swoimi treściami z lat 2005–2015 zalewają topkę. Świeżemu domenowi po prostu trudno się przebić w czołówkę bez znaczącej ilości backlinków.

To, co zadziałało, to moja druga domena z tym samym contentem — [maturapolski.pl](https://maturapolski.pl). Statyczna, ten sam Astro stack co poradniki, identyczne URL-e do tej samej bazy wiedzy, ale wcześniej zaindeksowana i z lepszym profilem backlinków z moich satelitów copywriterskich. Pozycja średnia 8.6, ~55 kliknięć i 3,9k wyświetleń miesięcznie z GSC. Z [maturapolski.pl](https://maturapolski.pl) systematycznie linkuję dofollow do [matury-online.pl](https://www.matury-online.pl) — kontekstowo z opracowań lektur, z hubów bazy wiedzy, z archiwum arkuszy. To jest off-page SEO w wykonaniu portfelowym: tania domena z silnym profilem podaje rękę dynamicznej SaaS, która sama jest jeszcze za młoda, żeby zarankować.

Wniosek: w niszy edukacyjnej z silną konkurencją statyczna domena-satelita pełniąca rolę gateway'a do SaaS robi większą robotę niż próba SEO-wania samej aplikacji.

## Co dalej

Z perspektywy infrastruktury wszystko działa stabilnie i kosztowo trzyma się w budżecie. Bottleneckiem nie jest stack, tylko organic acquisition. Najbliższe miesiące to systematyczne wzmacnianie [matury-online.pl](https://www.matury-online.pl) backlinkami z mojego portfela domen edukacyjnych ([licencjackie.pl](/blog/15-stron-w-astro-na-aws/), praca-magisterska.pl, prace-magisterskie.pl, magisterkaonline.com.pl) plus rozbudowa bazy treściowej na maturapolski.pl, żeby gateway dalej działał.

Po stronie produktu: rozszerzanie funkcji oceniania na inne przedmioty (matematyka i angielski na pierwszym ogniu), [interaktywna symulacja egzaminu](https://www.matury-online.pl/egzamin/polski-podstawowy) z timer'em i instant feedback po zakończeniu, integracja Stripe w trybie subskrypcyjnym (dziś dominuje pay-as-you-go za pojedyncze oceny).

Jeśli chcesz zobaczyć, jak to wszystko wygląda od strony użytkownika końcowego — [matury-online.pl jest publicznie dostępne](https://www.matury-online.pl), pierwsze zadania można rozwiązywać bez konta.

Jeśli budujesz coś podobnego — edukacyjny SaaS w niszy polskojęzycznej, statyczne SEO plus dynamiczna apka — chętnie pogadam. Zostaw kontakt na [stronie głównej](/) albo napisz na maila.
