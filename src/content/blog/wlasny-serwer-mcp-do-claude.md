---
title: "Własny serwer MCP do Claude.ai - jak dałem Claude bezpośredni dostęp do AWS, SSH, baz danych i kodu na moim dysku"
description: "Case study z budowy self-hosted serwera MCP (Model Context Protocol) dla Claude.ai web. Dziewięć narzędzi: AWS CLI, SSH, lokalny shell, zapis plików, GitHub API, PostgreSQL przez SSH, PM2, chunking długich dokumentów. OAuth 2.1 + PKCE, około 1000 linii Node.js, hosting na własnym Windows + FRP tunnel + nginx na VPS. Klucze nigdy nie opuszczają mojej maszyny."
pubDate: 2026-05-19
heroImage: "/images/blog/mcp-server-claude-ai.jpg"
heroImageAlt: "Schemat architektury własnego serwera MCP - Claude.ai łączy się przez OAuth z lokalnym Node.js, który ma dostęp do AWS, SSH, PostgreSQL i kodu na dysku"
category: "ai-copywriting"
tags:
  [
    "mcp",
    "model context protocol",
    "claude",
    "claude.ai",
    "oauth",
    "self-hosted",
    "automatyzacja",
    "ai tools",
    "case study"
  ]
draft: false
author: "Karol Leszczyński"
pillar: true
relatedPosts: ["ai-w-aplikacjach", "jak-obsługuje-30-domen-na-aws"]
---

Pracuję w Claude.ai cały dzień. Nie w Claude Code, nie w Cursor, nie w Claude Desktop - w przeglądarkowym czacie. To jest moje główne narzędzie do myślenia, pisania i debugowania kodu. Ale miało jedno ograniczenie, które męczyło mnie od miesięcy.

Claude nie mógł niczego zrobić u mnie. Mogłem mu opisać problem, pokazać kod, wkleić logi - ale nie mógł sam sprawdzić procesów na moim serwerze, nie mógł odpalić `aws ec2 describe-instances`, nie mógł zajrzeć do bazy `smart_edu` żeby policzyć użytkowników. Każda taka operacja kończyła się tak samo: ja wklejam komendę, kopiuję output, wracam do czatu, wklejam output, czekam na interpretację. Pętla skracała mi dzień o godzinę.

Zbudowałem własny serwer MCP, który tę pętlę likwiduje. To około 1000 linii Node.js, dziewięć narzędzi, OAuth 2.1 z PKCE i tunel z mojego Windows na VPS z nginx. Claude w przeglądarce widzi go jako "connector" i może z poziomu czatu odpalać komendy AWS CLI, SSH na moje EC2, zapytania SQL do Postgresa i edytować pliki na moim dysku. Klucze prywatne nigdy nie opuszczają mojej maszyny.

W tym artykule rozkładam to na części pierwsze: co dokładnie umie ten serwer, jak jest zbudowany, gdzie były pułapki i kiedy w ogóle warto coś takiego stawiać.

## Co to jest MCP w jednym zdaniu

Model Context Protocol to otwarty protokół Anthropic, który pozwala modelowi językowemu wywoływać funkcje na zewnętrznym serwerze. Pisząc do Claude w czacie mówisz "sprawdź X", on rozpoznaje że ma do dyspozycji narzędzie pasujące do tej intencji, wysyła do mojego serwera JSON-RPC z parametrami, dostaje odpowiedź i włącza ją do swojej odpowiedzi.

Claude.ai obsługuje dwa rodzaje takich serwerów. Pierwsze to gotowe integracje od Anthropic i firm trzecich - Gmail, Google Drive, Stripe, Canva i tak dalej. Drugi rodzaj to "custom connectors" - dowolny serwer HTTP, który Ty hostujesz i podpinasz pod swoje konto w `Settings → Connectors`. Mój należy do drugiej grupy.

## Czego nie umieją gotowe rozwiązania

Najprościej byłoby przejść na Claude Code lub Cursor - tam Claude ma natywny dostęp do plików, terminala, git i języków programowania. Próbowałem. Wracam do przeglądarki za każdym razem, bo czat na claude.ai jest dla mnie miejscem do myślenia, nie do edycji jednego pliku. Mam tam otwartych pięć rozmów równolegle, każda o innym projekcie, każda z własną historią.

Claude Desktop, z którego mógłbym podpiąć lokalne pliki, działa tylko z plikami i tylko na maszynie z aplikacją. Nie zalogujesz się do AWS przez konfigurację Desktop, nie odpalisz SSH na zdalny serwer, nie zapytasz Postgresa.

Custom connector daje wszystko trzy rzeczy naraz: czat w przeglądarce, dostęp do plików, dostęp do dowolnego API i SSH. Cena jest taka, że trzeba ten serwer napisać i hostować.

## Dziewięć narzędzi - co dokładnie umiem zlecić Claude'owi

Każde narzędzie w MCP to nazwana funkcja z opisem i schemą parametrów. Claude czyta opis i sam decyduje którą funkcję wywołać.

**`aws_cli`** - dowolna komenda AWS CLI bez prefiksu `aws`. Działa na lokalnie skonfigurowanym profilu, więc Claude dziedziczy moje uprawnienia. Komenda `ec2 describe-instances --region eu-central-1` zwraca listę moich maszyn z metadanymi.

**`ssh_exec`** - shell na zdalnym hoście. Parametry: nazwa klucza z `hosts.json`, user (domyślnie `ubuntu`), host (IP lub DNS), komenda. Klucz `.pem` zostaje na mojej maszynie, Claude widzi tylko alias. Typowy use case: `pm2 list`, `tail -n 50 /var/log/nginx/error.log`, `df -h`.

**`local_exec`** - shell na maszynie gdzie chodzi serwer MCP, czyli mój Windows. Na Windows idzie do `cmd.exe`, na Linux do `/bin/sh`. Używam do git, npm, kompilacji, testów.

**`write_file`** - zapis pliku przez Node.js `fs.writeFile`. Tworzy katalogi nadrzędne, obsługuje pełne UTF-8, działa też w trybie `append`. Brzmi banalnie, ale to najważniejsze narzędzie w całym zestawie - bez niego wszelkie próby zapisu długiego pliku z polskimi znakami przez `cmd.exe` kończą się rozjebanym kodowaniem. Ten artykuł powstaje właśnie przez `write_file`.

**`github_api`** - dowolny request do GitHub REST API. Token PAT jest w `.env` po stronie serwera, więc Claude widzi tylko "wywołaj endpoint X". Jest skrót: jeśli endpoint zaczyna się od `/repos/nazwa-repo/...` bez ownera, serwer dokleja domyślnego ownera z `.env`.

**`postgres_query`** - SQL na zdalnej bazie przez SSH. Zapytanie idzie przez `sudo -u postgres psql`, więc bazy słuchające tylko na `127.0.0.1` (czyli wszystkie moje produkcyjne) są dostępne bez wystawiania portu na świat. Format wyjścia do wyboru: `table`, `csv`, `json`.

**`pm2_status`** - status procesów PM2 na zdalnym hoście, opcjonalnie z ostatnimi N liniami logów. Działa też pod NVM-em (skrypt sam sourcuje `nvm.sh`).

**`book_split` + `book_chunk` + `book_note`** - trójka narzędzi do pracy z długimi dokumentami, które nie mieszczą się w kontekście. `book_split` dzieli plik na fragmenty po około 3000 słów respektując akapity i końce zdań, `book_chunk` czyta jeden fragment po indeksie, `book_note` prowadzi strukturalne notatki w JSON-ie obok korpusu (postacie, streszczenia rozdziałów, glosariusz). Używam tego do analiz książek na poziomie magisterskim - Claude czyta dokument iteracyjnie, robi notatki, na końcu syntetyzuje.

<!-- SCREEN: zrzut Claude.ai z rozwiniętą sekcją "Tools" i widocznymi narzędziami z mcp.torweb.pl -->

## Architektura - jak to się wszystko łączy

Cały system to trzy warstwy.

**Warstwa 1: Claude.ai (przeglądarka).** Otwieram czat, mam włączony toggle "mcp.torweb.pl" w connectors. Claude widzi listę dziewięciu narzędzi z opisami i parametrami.

**Warstwa 2: VPS na AWS EC2 (publiczny IP).** Na nim działa nginx i FRP server (`frps`). Nginx słucha na portach 80/443 i robi reverse proxy z subdomeny `mcp.torweb.pl` na `127.0.0.1:8080`. FRP server na porcie 7000 czeka na połączenie od klienta. To jedyna maszyna z publicznym IP w tym setupie.

**Warstwa 3: Mój Windows (bez publicznego IP).** Na nim chodzi `frpc.exe` (klient FRP) i `node server.js` na porcie 4500. FRP otwiera tunel zwrotny - to klient inicjuje połączenie do `frps`, więc nie muszę otwierać żadnych portów w domowym routerze. Każdy request `https://mcp.torweb.pl/mcp` ląduje fizycznie na mojej maszynie w salonie.

Klucze prywatne SSH leżą na moim dysku w `~/.ssh/`. AWS credentials w `~/.aws/credentials`. Hasło Postgres zaszyte w pliku `.pgpass` na zdalnych serwerach. **Nic z tego nie jest na VPS-ie. VPS to tylko ścieżka dla pakietów HTTP.**

Tak wygląda to w jednym wierszu:

```
Claude.ai → https://mcp.torweb.pl → nginx → FRP tunnel → Node.js (mój komputer)
                                                              ↓
                                          AWS CLI / SSH / Postgres / GitHub / pliki
```

## Stack techniczny

Serwer to pojedynczy plik `server.js`, około 1000 linii. Wybrałem Node.js bo Anthropic ma oficjalne SDK MCP w TypeScript/JS (`@modelcontextprotocol/sdk`), więc 80% pracy to opakowanie istniejących funkcji w schematy Zod.

Kluczowe zależności:

```json
{
  "@modelcontextprotocol/sdk": "^1.20.2",
  "express": "^4.21.2",
  "express-rate-limit": "^7.4.1",
  "helmet": "^8.0.0",
  "zod": "^3.23.8",
  "dotenv": "^16.4.7"
}
```

OAuth 2.1 z PKCE jest wymagany przez Claude.ai dla custom connectors. Implementacja w `server.js` ma cztery endpointy: discovery (`/.well-known/oauth-authorization-server`), dynamic client registration (`/oauth/register`), authorize z formularzem logowania (`/oauth/authorize`) i token exchange (`/oauth/token`). Plus rewokacja zgodna z RFC 7009.

Stan OAuth (clienci, kody autoryzacji, tokeny dostępu i odświeżania, dynamiczna lista IP) jest serializowany do `oauth-state.json` przy każdej zmianie i ładowany przy starcie. Restart serwera nie wylogowuje Claude'a - tokeny żyją 30 dni domyślnie, refresh token rotuje przy każdym użyciu.

## Bezpieczeństwo - co mnie chroni

Pierwsze pytanie znajomych: "ale jak to, dajesz LLM-owi dostęp do swoich serwerów? Nie boisz się że odpali `rm -rf /` na produkcji?"

Mogę. Jeśli go o to wprost poproszę. Więc nie proszę. To samo ryzyko co z każdym terminalem - jak wkleisz tam `sudo dd if=/dev/random of=/dev/sda`, też to wykona. Claude nie inicjuje destrukcyjnych akcji z własnej woli, tylko w odpowiedzi na moje polecenia.

Realne mechanizmy ochrony:

**OAuth 2.1 z PKCE.** Każde połączenie z Claude.ai musi mieć ważny `access_token` w nagłówku `Authorization: Bearer ...`. Token jest losowy (32 bajty z `crypto.randomBytes`), porównywany w stałym czasie (`crypto.timingSafeEqual`).

**Single-user.** Nie ma multi-tenant. Loguję się jako `MCP_USER`/`MCP_PASS` z `.env`. Tylko ja.

**IP allowlist z auto-enroll.** Endpoint `/mcp` sprawdza adres IP - jeśli nie jest na liście statycznej z `.env` ani na dynamicznej (zbudowanej przy ostatnim logowaniu), zwraca 401 z nagłówkiem `WWW-Authenticate` żeby Claude.ai sam zainicjował nowy login OAuth. Po udanym loginie podsieć `/24` adresu źródłowego jest dodawana na 30 dni (Claude.ai rotuje IP w obrębie tego samego ASN, więc per-IP byłoby za ciasno).

**Rate limit.** 30 requestów na 15 minut na `/oauth/token`, `/oauth/authorize` i `/oauth/revoke`. Bruteforce na login pada po pierwszej minucie.

**Whitelist kluczy SSH.** `ssh_exec` przyjmuje nazwę klucza z `hosts.json`, nie ścieżkę. Claude nie może powiedzieć "weź klucz spod `/etc/passwd`".

**helmet + CSP** na formularzu logowania (anti-clickjacking, blokowane wszystkie zewnętrzne źródła).

**Logi z redakcją.** Każdy request OAuth/MCP idzie do `logs/mcp.log`. Pola wrażliwe (`password`, `client_secret`, `code_verifier`, `refresh_token`, `code`, `access_token`) są zamieniane na `[REDACTED]` przed zapisem.

**Klucze nigdy nie jadą na zewnątrz.** Powtarzam to celowo. AWS credentials, klucze SSH i `.env` z PAT-em GitHuba siedzą na mojej maszynie. VPS widzi tylko zaszyfrowany ruch HTTP.

## Uruchomienie na Windowsie - Task Scheduler

Setup, na którym wylądowałem po próbach z PM2:

Zadanie w Task Scheduler z triggerem `AtLogon` uruchamia `wscript.exe "D:\mcp-server\start-mcp-hidden.vbs"`. Plik VBS odpala `start-mcp.bat` bez okienka konsoli:

```bat
@echo off
cd /d D:\mcp-server
if not exist logs mkdir logs
:loop
node server.js >> logs\mcp.log 2>&1
echo [%date% %time%] node exited, restarting in 5s >> logs\mcp.log
timeout /t 5 /nobreak >nul
goto loop
```

Prosta pętla while - jeśli node padnie z dowolnego powodu, restart za 5 sekund. Logi append do jednego pliku. Po zalogowaniu do Windows MCP startuje automatycznie, schowany w tle.

PM2 z `--watch` próbowałem wcześniej, ale auto-reload na każdą zmianę pliku zabija aktywną sesję MCP w Claude'cie. Lepszy jest ręczny restart wtedy, kiedy ja go potrzebuję.

FRP tunnel startuję analogicznie - drugi VBS, drugi task. Bez tunelu nginx na VPS dostanie 502, ale sam node nadal chodzi.

## Pułapki, które przeszedłem

Pełna lista bólu z dwóch tygodni iteracji.

**1. Restart serwera zrywa sesję MCP.** Jak edytuję `server.js` i restartuję node, Claude w przeglądarce dostanie błąd `Session terminated` przy kolejnym tool callu. Jedyne wyjście to powiedzieć użytkownikowi "restartuje się, wyślij dowolny komunikat żeby się przepiąć". Nowa wiadomość = nowa sesja.

**2. Nowe tooly nie pojawiają się w trwającym czacie.** Lista narzędzi jest ładowana raz na początku konwersacji. Dodałem `write_file`, restart serwera - i w bieżącym czacie nadal go nie widzę. Trzeba otworzyć nowy chat (nie nową wiadomość, *nowy chat*).

**3. cmd.exe rozwala UTF-8.** Każda próba zapisu polskich znaków przez `echo "..." > plik.md` daje krzaczki. Każda próba użycia `powershell -Command "..."` z heredockiem rozwala się na cytowaniu. Dlatego `write_file` istnieje - omija cały warstwę shella i pisze bezpośrednio przez Node.js.

**4. PKCE musi być S256 i base64url.** Pierwszy MVP przyjmował też `plain` - Claude.ai natychmiast wywalił błąd. Trzeba liczyć SHA-256 z `code_verifier`, kodować jako base64url (`base64.replace(/+/g, '-').replace(/\//g, '_').replace(/=+$/, '')`) i porównywać `timingSafeEqual`.

**5. Claude.ai rotuje IP.** Pierwsza wersja allowlisty zapisywała pojedyncze IP-ki po loginie. Po godzinie Claude przychodził z innego adresu w tej samej podsieci i dostawał 401. Rozwiązanie: enrolluj `/24` (256 adresów). Trade-off akceptowalny dla single-user setupu.

**6. Token endpoint authentication.** Claude.ai wysyła `client_secret` w body POST (zgodnie z RFC), ale niektóre tutoriale pokazują Basic Auth w nagłówku. Pierwsza wersja przyjmowała tylko nagłówek - Claude.ai nie potrafił się zalogować.

**7. SSE timeouty na nginx.** MCP używa Server-Sent Events na długich połączeniach. Domyślny nginx zamyka połączenie po 60 sekundach. Trzeba `proxy_read_timeout 3600s`, `proxy_buffering off` i `proxy_http_version 1.1`.

## Realne case studies z pracy

Pomijam smoke testy i syntetyczne przykłady - tu są konkretne sytuacje z ostatniego miesiąca.

**Audyt produkcji bez wychodzenia z czatu.** Klient pisze że strona maturapolski.pl wolno odpowiada. Wpisuję do Claude: "Sprawdź dlaczego matury wolno chodzą, hostgame 3.68.187.152, klucz maturapolski". Claude równolegle odpala `ssh_exec` z `uptime && free -h && pm2 list && tail -n 100 /var/log/nginx/error.log` i drugi z `pm2 logs maturapolski-backend --lines 200`. Po 8 sekundach dostaję podsumowanie: backend zjada 2.1 GB RAM, jest swap, load avg 4.5. Bez MCP zajęłoby mi to 4 minuty klikania w terminalu.

**Migracja kolumny na produkcji.** "Dodaj kolumnę `subscription_renewed_at TIMESTAMP` do tabeli `users` w bazie `smart_edu` na panel hoście. Najpierw sprawdź czy nie istnieje". Claude: `postgres_query SELECT column_name FROM information_schema.columns WHERE table_name='users'`, widzi że nie istnieje, odpala `ALTER TABLE users ADD COLUMN subscription_renewed_at TIMESTAMP`, weryfikuje, kończy. Cały dialog: trzy linie ode mnie, dwie minuty.

**Pisanie kodu bezpośrednio na dysk.** Pracuję nad nowym komponentem Astro do bloga. Claude generuje strukturę plików (`Layout.astro`, `BlogPost.astro`, `BlogList.astro`) i sam zapisuje przez `write_file` do `D:\karol-leszczynski.pl\src\components\blog\`. Następnie `local_exec` na `cd D:\karol-leszczynski.pl && npm run build` i widzimy czy się skompilowało. Wszystko z poziomu jednego okna przeglądarki.

**Hotfix do repo przez GitHub API.** "Wypchnij fix do `karol-leszczynski-pl` na branch `main`, plik `src/utils/seo.ts`, zmień linię 42 z X na Y". Claude: `github_api GET /repos/X/contents/src/utils/seo.ts` żeby dostać SHA, lokalnie modyfikuje, `PUT` z nowym contentem i message commit. Bez wychodzenia z czatu i bez clone'owania repo.

**Audyt billingu AWS.** "Pokaż mi instancje EC2 w trzech regionach, ile kosztują, czy są w użyciu, czy mam jakieś zapomniane volumes EBS". Trzy równoległe `aws_cli describe-instances` na regiony plus `describe-volumes` plus `pricing get-products`. Dostaję tabelę. Znajduję dwa nieużywane volume'y z grudnia - 8 EUR/mc oszczędności w minutę.

<!-- SCREEN: zrzut czatu z Claude.ai pokazujący równoległe wywołanie ssh_exec, postgres_query i pm2_status z odpowiedziami -->

## Ograniczenia, których nie da się zignorować

**Tokeny żyją 30 dni.** Domyślne TTL. Po tym czasie Claude.ai sam odpala OAuth flow w tle przez refresh token, ale jeśli nie używałem connectora przez ponad miesiąc, dostanę formularz logowania. Można wydłużyć w `.env`.

**Komputer musi być włączony.** FRP tunnel = mój Windows. Jak go uśpię, MCP umiera. Częściowe rozwiązanie: serwer mógłby równie dobrze stać na VPS-ie, ale wtedy klucze SSH i AWS musiałyby być na VPS-ie, co psuje główną zaletę setupu (klucze u mnie).

**120 sekund timeoutu na komendę.** `node-exec` z domyślnym timeoutem. Długie buildy npm i wielogodzinne migracje SQL nie zadziałają.

**10 MB buffera output.** Można podnieść, ale i tak Claude.ai nie poradzi sobie z odebraniem 50 MB JSON-a w jednym tool callu. Trzeba paginować.

**Token MUSI lecieć przez HTTPS.** Nie da się tego uruchomić na `http://`. Stąd nginx + Let's Encrypt na VPS-ie. Lokalny test też wymaga `mkcert` lub podobnego.

**Brak rate-limitu na narzędzia.** Claude może odpalić `aws_cli` 30 razy z rzędu i AWS go zablokuje (limit API). Pilnuję tego po stronie promptów - nie pozwalam mu loopować bez powodu.

## Kiedy warto, a kiedy nie

**Warto, jeśli:**

- Pracujesz w Claude.ai (web) jako głównym narzędziu i czat jest dla Ciebie szybszy niż edytor
- Masz infrastrukturę do zarządzania - kilka serwerów EC2, kilka baz, repo na GitHubie, projekty rozsiane po katalogach
- Lubisz mieć kontrolę nad swoim toolingiem, gotów jesteś dotknąć Node.js i nginx
- Chcesz w czacie pisać tekst i jednocześnie publikować go na dysk bez kopiuj-wklej

**Nie warto, jeśli:**

- Już używasz Claude Code, Cursor albo Continue.dev - tam dostęp do plików i terminala jest natywny, MCP byłoby nadmiarowe
- Nie chcesz administrować Node.js, nginx i FRP - to nie jest wielka maszynka, ale wymaga ~3-5 godzin setupu i potem doglądania logów raz na tydzień
- Twoja praca z Claude'em to głównie pisanie tekstów bez kontekstu z infrastruktury (np. copywriting bez integracji z CMS) - nic byś tu nie zyskał
- Hosting na własnej maszynie nie wchodzi w grę (laptop często śpi, brak stałego prądu) - rozwiązanie: postaw serwer na VPS-ie, ale wtedy klucze i AWS leżą tam, co osłabia bezpieczeństwo

## Czas i koszt

**Pierwsza działająca wersja:** jedno popołudnie. Pusty MVP z `aws_cli` i `local_exec` + OAuth + tunel FRP na istniejącym VPS-ie = około 6 godzin.

**Stabilna wersja produkcyjna:** trzy tygodnie iteracji. Doszły: PKCE poprawnie, persistence stanu OAuth, IP allowlist, refresh token rotation, helmet, rate limit, lepsze error messages, narzędzia do długich dokumentów, `write_file`, Task Scheduler.

**Koszt miesięczny:** VPS t3.small na AWS w `eu-central-1` = około 14 EUR/mc, w tym mam już inne usługi. Sam MCP nie wymaga oddzielnej maszyny. Jeśli stawiasz od zera: VPS za 4-5 EUR/mc (Hetzner CX11, OVH VPS Starter) + domena 10 EUR/rok + Let's Encrypt darmowy. Wszystko inne open source.

**Rozmiar kodu:** `server.js` ma 1041 linii. Bez zewnętrznych mikroserwisów, bez Dockera (choć można), bez bazy danych - całe state'y w jednym JSON-ie.

## Open source

Wszystko leży na moim GitHubie pod licencją MIT. Włącznie z gotowymi `setup.bat`, `setup.sh`, `.env.example`, `hosts.example.json` i przykładową konfiguracją Task Scheduler w XML-u (eksport zadania). README jest po angielsku, drugi po polsku. Jeśli chcesz to postawić u siebie, czytaj `README.md` od początku i nie omijaj sekcji "Security" - jeden źle skonfigurowany `MCP_TRUST_PROXY` i każdy może udawać że jest Twoim IP.

## Czego się nauczyłem

Najważniejszy wniosek nie jest techniczny. MCP zmienia model pracy z LLM-em z konsultacyjnego na operacyjny. Bez niego Claude jest doradcą - mówi co zrobić, ja klikam. Z nim jest wykonawcą - ja mówię co osiągnąć, on klika. To różnica jakościowa, nie ilościowa.

Drugi wniosek: dla większości ludzi to przesada. Claude Code lub Cursor zaspokoi 90% potrzeb przy 10% wysiłku. Custom MCP server ma sens, jeśli Twoje narzędzie pracy to konkretnie `claude.ai/chat` i nie chcesz tego zmieniać.

Trzeci: małe rzeczy są najważniejsze. Najbardziej zmieniło mój workflow nie OAuth ani SSH, tylko `write_file`. Pojedyncza funkcja zapisująca tekst do pliku, bez której nie powstałby ten artykuł.
