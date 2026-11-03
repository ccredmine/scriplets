#!/usr/bin/env bash
# ╭────────────────────────────────────────────────────────────────────╮
# │  REDMINE SYNC – Tickets als RTF bearbeiten und zurücksynchronisieren │
# ╰────────────────────────────────────────────────────────────────────╯
# Ablauf:
#   1. Ticket-ID eingeben → Ticket wird im Terminal angezeigt
#   2. current-ticket.rtf (neben diesem Script) wird geschrieben und im
#      Standard-Editor (TextEdit) geöffnet
#   3. Datei bearbeiten + speichern → Änderung wird erkannt → ✔
#   4. ENTER synchronisiert: Beschreibung, bearbeitete Kommentare,
#      neuer Kommentar → zurück zur Startseite, RTF wird geleert
# Benötigt: bash ≥ 3.2, curl, jq, textutil (macOS)
set -u

# ── UTF-8 sicherstellen (Rahmen, Umlaute) ───────────────────────────────
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf8*|*UTF8*) ;;
    *) export LC_ALL=en_US.UTF-8 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.redmine_config"
RTF_NAME="current-ticket.rtf"
RTF_FILE="$SCRIPT_DIR/$RTF_NAME"
MAX_COMMENTS_TERM=3
# In der RTF landen immer alle Kommentare in voller Länge; im Terminal nur die ersten MAX_COMMENTS_TERM.

# ── Terminal / Farben ────────────────────────────────────────────────────
if [ -t 1 ]; then TTY=1; else TTY=0; fi
if [ "$TTY" = 1 ]; then
    BOLD=$'\033[1m'  RST=$'\033[0m'  GRY=$'\033[90m'
    CYN=$'\033[36m'  GRN=$'\033[32m' RED=$'\033[31m' YEL=$'\033[33m' MAG=$'\033[35m'
else
    BOLD='' RST='' GRY='' CYN='' GRN='' RED='' YEL='' MAG=''
fi

TCOLS=100; TLINES=30; CW=96
TICKET_ID=""; CUR_ID=""; ISSUE_JSON=""; COMMENTS_JSON="[]"; ORIG_DESC=""
API_CODE=""; API_BODY=""; CONN_INFO=""; LOGO_LINES=6; BW=0; IW=0; LP=0

term_size() {
    TCOLS=$(tput cols 2>/dev/null)  || TCOLS=""
    TLINES=$(tput lines 2>/dev/null) || TLINES=""
    [[ "$TCOLS"  =~ ^[0-9]+$ ]] || TCOLS=100
    [[ "$TLINES" =~ ^[0-9]+$ ]] || TLINES=30
    CW=$((TCOLS - 4)); [ "$CW" -lt 40 ] && CW=40
}
cls()         { [ "$TTY" = 1 ] && printf '\033[H\033[2J\033[3J'; return 0; }
hide_cursor() { [ "$TTY" = 1 ] && printf '\033[?25l'; return 0; }
show_cursor() { [ "$TTY" = 1 ] && printf '\033[?25h'; return 0; }
trap 'show_cursor' EXIT
trap 'show_cursor; printf "\n"; exit 130' INT

# ── Abhängigkeiten ───────────────────────────────────────────────────────
for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        printf '%s✖%s %s fehlt → brew install %s\n' "$RED" "$RST" "$cmd" "$cmd"; exit 1
    fi
done

# ── Render-Helfer (cli-Stil: Rules, Alerts, Boxen) ───────────────────────
rep()    { [ "$2" -gt 0 ] || return 0; local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }
trunc()  { if [ "${#1}" -gt "$2" ]; then printf '%s…' "${1:0:$(($2 - 1))}"; else printf '%s' "$1"; fi; }
padr()   { printf '%s' "$1"; [ "${#1}" -lt "$2" ] && printf '%*s' $(($2 - ${#1})) ''; return 0; }
center() { local pad=$(( (TCOLS - ${#1}) / 2 )); [ "$pad" -lt 0 ] && pad=0; printf '%*s%s\n' "$pad" '' "${2:-$1}"; }
h1()     { printf '%s── %s%s%s%s %s%s\n' "$CYN" "$BOLD" "$1" "$RST" "$CYN" "$(rep '─' $((TCOLS - ${#1} - 6)))" "$RST"; }
rule()   { printf '%s%s%s\n' "$GRY" "$(rep '─' $((TCOLS - 2)))" "$RST"; }
ok()     { printf '  %s✔%s %s\n' "$GRN" "$RST" "$1"; }
err()    { printf '  %s✖%s %s\n' "$RED" "$RST" "$1"; }
info()   { printf '  %sℹ%s %s\n' "$CYN" "$RST" "$1"; }
warn()   { printf '  %s!%s %s\n' "$YEL" "$RST" "$1"; }

# Absatz umbrechen: para TEXT EINZUG MAXZEILEN
para() {
    local text ind="$2" max="$3" w=$((CW - $2)) pad total
    text=$(printf '%s' "$1" | tr -d '\r')
    pad=$(rep ' ' "$ind")
    if [ -z "$text" ]; then printf '%s%s—%s\n' "$pad" "$GRY" "$RST"; return; fi
    total=$(printf '%s\n' "$text" | fold -s -w "$w" | wc -l | tr -d ' ')
    printf '%s\n' "$text" | fold -s -w "$w" | head -n "$max" | sed "s/^/$pad/"
    [ "$total" -gt "$max" ] && printf '%s%s… %d weitere Zeilen%s\n' "$pad" "$GRY" $((total - max)) "$RST"
    return 0
}

# Zwei Metadaten-Spalten: meta_row LABEL WERT LABEL WERT
meta_row() {
    local lw=13 vw
    if [ "$CW" -ge 80 ]; then
        vw=$((CW / 2 - 17))
        printf '  %s%s%s %s  ' "$GRY" "$(padr "$1" $lw)" "$RST" "$(padr "$(trunc "$2" $vw)" $vw)"
        printf '%s%s%s %s\n'    "$GRY" "$(padr "$3" $lw)" "$RST" "$(trunc "$4" $vw)"
    else
        vw=$((CW - 16))
        printf '  %s%s%s %s\n' "$GRY" "$(padr "$1" $lw)" "$RST" "$(trunc "$2" $vw)"
        printf '  %s%s%s %s\n' "$GRY" "$(padr "$3" $lw)" "$RST" "$(trunc "$4" $vw)"
    fi
}

# ISO-8601 (UTC) → lokal "TT.MM.JJJJ HH:MM"
fmt_date() {
    local iso="$1" ep
    if [ -z "$iso" ] || [ "$iso" = "null" ]; then printf '—'; return; fi
    if ep=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" +%s 2>/dev/null); then
        date -r "$ep" '+%d.%m.%Y %H:%M'
    elif date -d "$iso" '+%d.%m.%Y %H:%M' 2>/dev/null; then :
    else printf '%s' "$iso"; fi
}

# ── Logo ─────────────────────────────────────────────────────────────────
LOGO_A=(
'██████╗ ███████╗██████╗ ███╗   ███╗██╗███╗   ██╗███████╗'
'██╔══██╗██╔════╝██╔══██╗████╗ ████║██║████╗  ██║██╔════╝'
'██████╔╝█████╗  ██║  ██║██╔████╔██║██║██╔██╗ ██║█████╗  '
'██╔══██╗██╔══╝  ██║  ██║██║╚██╔╝██║██║██║╚██╗██║██╔══╝  '
'██║  ██║███████╗██████╔╝██║ ╚═╝ ██║██║██║ ╚████║███████╗'
'╚═╝  ╚═╝╚══════╝╚═════╝ ╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚══════╝'
)
LOGO_B=(
'███████╗██╗   ██╗███╗   ██╗ ██████╗'
'██╔════╝╚██╗ ██╔╝████╗  ██║██╔════╝'
'███████╗ ╚████╔╝ ██╔██╗ ██║██║     '
'╚════██║  ╚██╔╝  ██║╚██╗██║██║     '
'███████║   ██║   ██║ ╚████║╚██████╗'
'╚══════╝   ╚═╝   ╚═╝  ╚═══╝ ╚═════╝'
)
draw_logo() {
    local i
    if [ "$TCOLS" -ge 98 ]; then
        for ((i = 0; i < 6; i++)); do
            center "${LOGO_A[i]}   ${LOGO_B[i]}" "${CYN}${LOGO_A[i]}${RST}   ${MAG}${LOGO_B[i]}${RST}"
        done
        LOGO_LINES=6
    else
        for ((i = 0; i < 6; i++)); do center "${LOGO_A[i]}" "${CYN}${LOGO_A[i]}${RST}"; done
        center 'S Y N C' "${MAG}${BOLD}S Y N C${RST}"
        LOGO_LINES=7
    fi
}

# ── Konfiguration / API ──────────────────────────────────────────────────
load_config() {
    [ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
    if [ -z "${REDMINE_URL:-}" ] || [ -z "${REDMINE_API_KEY:-}" ]; then
        term_size; cls; echo
        h1 'Einrichtung'; echo
        printf '  Redmine-URL (z. B. https://pm.example.com): '; IFS= read -r REDMINE_URL
        printf '  API-Key (Redmine → Mein Konto → API-Zugriffsschlüssel): '; IFS= read -rs REDMINE_API_KEY; echo
        REDMINE_URL=${REDMINE_URL%/}
        printf 'REDMINE_URL="%s"\nREDMINE_API_KEY="%s"\n' "$REDMINE_URL" "$REDMINE_API_KEY" > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        ok "Konfiguration gespeichert: $CONFIG_FILE"; sleep 1
    fi
    REDMINE_URL=${REDMINE_URL%/}
}

# api METHODE PFAD [JSON]  → setzt API_CODE / API_BODY
api() {
    local method="$1" path="$2" data="${3:-}" out
    if [ -n "$data" ]; then
        out=$(curl -s --max-time 30 -w $'\n%{http_code}' -X "$method" \
              -H "X-Redmine-API-Key: $REDMINE_API_KEY" -H 'Content-Type: application/json' \
              --data-binary "$data" "$REDMINE_URL$path" 2>/dev/null)
    else
        out=$(curl -s --max-time 30 -w $'\n%{http_code}' -X "$method" \
              -H "X-Redmine-API-Key: $REDMINE_API_KEY" "$REDMINE_URL$path" 2>/dev/null)
    fi
    API_CODE=${out##*$'\n'}
    API_BODY=${out%$'\n'*}
    [[ "$API_CODE" =~ ^[0-9]{3}$ ]] || { API_CODE=000; API_BODY=''; }
}
show_api_errors() { printf '%s' "$API_BODY" | jq -r '.errors[]? | "      • " + .' 2>/dev/null; return 0; }
jf() { printf '%s' "$ISSUE_JSON" | jq -r "$1 // \"\""; }

check_connection() {
    api GET '/users/current.json'
    local who
    case "$API_CODE" in
        200) who=$(printf '%s' "$API_BODY" | jq -r '[.user.firstname // "", .user.lastname // ""] | join(" ")')
             CONN_INFO="✔ Verbunden mit ${REDMINE_URL#*://} als ${who# }" ;;
        401) term_size; cls; echo
             err "API-Key ungültig (HTTP 401)."
             printf '     Key in %s eintragen – Redmine → Mein Konto → API-Zugriffsschlüssel.\n' "$CONFIG_FILE"
             exit 1 ;;
        *)   term_size; cls; echo
             err "Keine Verbindung zu $REDMINE_URL (HTTP $API_CODE)."; exit 1 ;;
    esac
}

# ── RTF ──────────────────────────────────────────────────────────────────
init_rtf() {  # leere, aber gültige RTF-Datei
    printf '%s\n' '{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0\fswiss\fcharset0 Helvetica;}}\f0\fs26 \par}' > "$RTF_FILE"
}
html_esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

write_rtf() {
    local pre='font-family: Helvetica; font-size: 13px; white-space: pre-wrap;'
    local tmp="$SCRIPT_DIR/.current-ticket.html" n i c cid cauthor cdate cnotes
    n=$(printf '%s' "$COMMENTS_JSON" | jq 'length')
    {
        printf '<html><head><meta charset="utf-8"></head>\n<body style="font-family: Helvetica; font-size: 13px;">\n'
        printf '<p><b style="font-size: 17px;">Ticket #%s – %s</b></p>\n' "$CUR_ID" "$(jf '.issue.subject' | html_esc)"
        printf '<p style="color: #666666;">Status: %s · Priorität: %s · Autor: %s · Erstellt: %s</p>\n' \
            "$(jf '.issue.status.name' | html_esc)" "$(jf '.issue.priority.name' | html_esc)" \
            "$(jf '.issue.author.name' | html_esc)" "$(fmt_date "$(jf '.issue.created_on')")"
        printf '<p style="color: #666666;">Text unterhalb der ===== Marker bearbeiten, Marker selbst nicht ändern. Speichern (⌘S) → im Terminal ENTER.</p>\n'
        printf '<p style="color: #666666;">Neuer Kommentar an beliebiger Stelle: Zeile <b>== KOMMENTAR TT.MM.JJJJ HH:MM ==</b> und darunter den Text – er wird mit diesem Zeitpunkt im Ticketverlauf einsortiert.</p>\n'
        printf '<p><b>===== BESCHREIBUNG =====</b></p>\n<pre style="%s">%s</pre>\n' "$pre" "$(printf '%s' "$ORIG_DESC" | tr -d '\r' | html_esc)"
        printf '<p><b>===== NEUER KOMMENTAR =====</b></p>\n<pre style="%s"></pre>\n' "$pre"
        for ((i = 0; i < n; i++)); do
            c=$(printf '%s' "$COMMENTS_JSON" | jq -c ".[$i]")
            cid=$(printf '%s' "$c" | jq -r '.id')
            cauthor=$(printf '%s' "$c" | jq -r '.user.name // "Unbekannt"' | html_esc)
            cdate=$(fmt_date "$(printf '%s' "$c" | jq -r '.created_on // ""')")
            cnotes=$(printf '%s' "$c" | jq -r '.notes' | tr -d '\r' | html_esc)
            printf '<p><b>===== KOMMENTAR %s · %s · %s =====</b></p>\n<pre style="%s">%s</pre>\n' "$cid" "$cauthor" "$cdate" "$pre" "$cnotes"
        done
        printf '</body></html>\n'
    } > "$tmp"
    if command -v textutil >/dev/null 2>&1; then
        textutil -convert rtf -inputencoding UTF-8 "$tmp" -output "$RTF_FILE" 2>/dev/null
    else  # Fallback ohne textutil: Text in minimales RTF verpacken
        {
            printf '%s\n' '{\rtf1\ansi\deff0{\fonttbl{\f0\fswiss Helvetica;}}\f0\fs26'
            sed -e 's#</p>#\n#g' -e 's#</pre>#\n#g' "$tmp" | sed -e 's/<[^>]*>//g' \
                -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&amp;/\&/g' \
                -e 's/\\/\\\\/g' -e 's/{/\\{/g' -e 's/}/\\}/g' -e 's/$/\\par/'
            printf '}\n'
        } > "$RTF_FILE"
    fi
    local rc=$?; rm -f "$tmp"; return $rc
}

rtf_to_text() {
    if command -v textutil >/dev/null 2>&1; then
        textutil -convert txt -encoding UTF-8 -stdout "$RTF_FILE"
    else
        sed -e 's/\\par[d]\{0,1\}/\n/g' -e "s/\\\\'[0-9a-fA-F][0-9a-fA-F]//g" \
            -e 's/\\[a-zA-Z][a-zA-Z0-9-]*[ ]\{0,1\}//g' -e 's/[{}]//g' "$RTF_FILE"
    fi
}
# Marker-Zeile: "== NAME … ==" bzw. "===== NAME … =====" (zwei oder mehr '=')
# Abschnitt unter "===== NAME ... =====" ausgeben
section() {
    awk -v target="$1" '
        /^==+ [^=].* ==+[[:space:]]*$/ {
            inner = $0; sub(/^==+ /, "", inner); sub(/ ==+[[:space:]]*$/, "", inner)
            on = (inner == target || index(inner, target " ") == 1); next
        }
        on { print }'
}
# Neue Kommentare mit Zeitstempel: "== KOMMENTAR TT.MM.JJJJ HH:MM ==" + Text darunter.
# Ausgabe pro Block: "@@NEW@@<TAB><datum zeit>", Textzeilen, "@@END@@"
extract_new_comments() {
    awk '
        /^==+ [^=].* ==+[[:space:]]*$/ {
            inner = $0; sub(/^==+ /, "", inner); sub(/ ==+[[:space:]]*$/, "", inner)
            if (on) { print "@@END@@"; on = 0 }
            if (inner ~ /^KOMMENTAR[ \t]+[0-9]+[.\/-][0-9]+[.\/-][0-9]+([ \t]+[0-9]+:[0-9]+(:[0-9]+)?)?[ \t]*$/) {
                dt = inner; sub(/^KOMMENTAR[ \t]+/, "", dt); sub(/[ \t]+$/, "", dt)
                print "@@NEW@@\t" dt; on = 1
            }
            next
        }
        on { print }
        END { if (on) print "@@END@@" }'
}
# Lokale Zeitangabe → ISO 8601 UTC (z. B. "02.11.2026 14:30" → 2026-11-02T13:30:00Z)
to_iso_utc() {
    local s="$1" ep="" f colons
    s=$(printf '%s' "$s" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's#/#.#g')
    colons=${s//[^:]/}
    case "${#colons}" in 0) s="$s 00:00:00" ;; 1) s="$s:00" ;; esac
    for f in '%d.%m.%Y %H:%M:%S' '%Y-%m-%d %H:%M:%S' '%d.%m.%y %H:%M:%S'; do
        ep=$(date -j -f "$f" "$s" +%s 2>/dev/null) && break
        ep=""
    done
    [ -n "$ep" ] || ep=$(date -d "$s" +%s 2>/dev/null) || return 1
    TZ=UTC date -r "$ep" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$ep" '+%Y-%m-%dT%H:%M:%SZ'
}
# Kommentar anlegen und ID des neuen Journals ermitteln → NEW_JOURNAL_ID
create_comment() {
    local text="$1" prev_max
    NEW_JOURNAL_ID=""
    api GET "/issues/$CUR_ID.json?include=journals"
    prev_max=$(printf '%s' "$API_BODY" | jq '[.issue.journals[]?.id] | max // 0' 2>/dev/null); prev_max=${prev_max:-0}
    api PUT "/issues/$CUR_ID.json" "$(jq -n --arg t "$text" '{issue: {notes: $t}}')"
    [ "$API_CODE" = 204 ] || [ "$API_CODE" = 200 ] || return 1
    api GET "/issues/$CUR_ID.json?include=journals"
    NEW_JOURNAL_ID=$(printf '%s' "$API_BODY" | jq -r --argjson p "$prev_max" --arg t "$text" \
        '[.issue.journals[]? | select(.id > $p)] | (map(select((.notes // "") | gsub("\r"; "") == $t)) + .) | first | .id // ""' 2>/dev/null)
    return 0
}
# Zeitstempel eines Kommentars setzen (redmine-extended-api: Backdating)
backdate_journal() {
    local jid="$1" iso="$2"
    api PUT "/issues/$CUR_ID/journals/$jid/backdate.json" "$(jq -n --arg c "$iso" '{created_on: $c}')"
    [ "$API_CODE" = 200 ]
}
# Vergleichs-Normalisierung: CR raus, Zeilenenden trimmen, Leerzeilen zusammenfassen/abschneiden
norm() { tr -d '\r' | sed -e 's/[[:space:]]*$//' | cat -s | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'; }
file_sig() { md5 -q "$1" 2>/dev/null || md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
open_file() {
    if command -v open >/dev/null 2>&1; then open "$1"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1" >/dev/null 2>&1 &
    else return 1; fi
}

# ── Startseite ───────────────────────────────────────────────────────────
box_line() {
    local fill=$((IW - 3 - ${#1})); [ "$fill" -lt 0 ] && fill=0
    printf '%*s%s│%s   %s%*s%s│%s\n' "$LP" '' "$CYN" "$RST" "${2:-$1}" "$fill" '' "$CYN" "$RST"
}
show_home() {
    TICKET_ID=""
    term_size; cls; echo
    draw_logo; echo
    center 'Ticket laden  ·  in RTF bearbeiten  ·  zurück nach Redmine' \
           "${GRY}Ticket laden  ·  in RTF bearbeiten  ·  zurück nach Redmine${RST}"

    # Eingabe-Box vertikal mittig
    local used=$((LOGO_LINES + 3)) top=$(( (TLINES - 8) / 2 - LOGO_LINES - 3 )) i
    [ "$top" -lt 1 ] && top=1
    for ((i = 0; i < top; i++)); do echo; done

    BW=52; [ "$BW" -gt $((TCOLS - 4)) ] && BW=$((TCOLS - 4))
    IW=$((BW - 2)); LP=$(( (TCOLS - BW) / 2 ))
    printf '%*s%s╭%s╮%s\n' "$LP" '' "$CYN" "$(rep '─' "$IW")" "$RST"
    box_line ''
    box_line 'Ticket-ID eingeben' "${BOLD}Ticket-ID eingeben${RST}"
    box_line ''
    box_line '❯' "${MAG}❯${RST}"
    box_line ''
    box_line 'ENTER  laden       q  beenden' "${GRY}ENTER  laden       q  beenden${RST}"
    printf '%*s%s╰%s╯%s\n' "$LP" '' "$CYN" "$(rep '─' "$IW")" "$RST"
    echo
    center "$CONN_INFO" "${GRY}${CONN_INFO}${RST}"

    # Cursor ins Eingabefeld (6 Zeilen hoch), danach wieder unter die Box
    local id
    [ "$TTY" = 1 ] && printf '\033[6A\033[%dG' $((LP + 7))
    IFS= read -r id || { [ "$TTY" = 1 ] && printf '\033[5B'; echo; exit 0; }
    [ "$TTY" = 1 ] && printf '\033[5B'
    echo

    id=${id//[[:space:]]/}; id=${id#\#}
    case "$id" in
        q|Q|quit|exit) center 'Auf Wiedersehen.' "${GRY}Auf Wiedersehen.${RST}"; echo; exit 0 ;;
        '') return 0 ;;
    esac
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
        center "✖ „${id}“ ist keine gültige Ticket-ID." "${RED}✖${RST} „${id}“ ist keine gültige Ticket-ID."
        sleep 1.5; return 0
    fi
    center "Lade Ticket #$id …" "${GRY}Lade Ticket #$id …${RST}"
    TICKET_ID="$id"
}

# ── Ticket-Ansicht ───────────────────────────────────────────────────────
show_ticket() {
    local id="$1"
    api GET "/issues/$id.json?include=journals"
    if [ "$API_CODE" != 200 ] || ! printf '%s' "$API_BODY" | jq -e '.issue.id' >/dev/null 2>&1; then
        echo
        case "$API_CODE" in
            404) center "✖ Ticket #$id existiert nicht." "${RED}✖${RST} Ticket #$id existiert nicht." ;;
            403) center "✖ Kein Zugriff auf Ticket #$id." "${RED}✖${RST} Kein Zugriff auf Ticket #$id." ;;
            *)   center "✖ Ticket #$id konnte nicht geladen werden (HTTP $API_CODE)." \
                        "${RED}✖${RST} Ticket #$id konnte nicht geladen werden (HTTP $API_CODE)." ;;
        esac
        sleep 2; return 1
    fi
    ISSUE_JSON="$API_BODY"; CUR_ID="$id"
    COMMENTS_JSON=$(printf '%s' "$ISSUE_JSON" | jq -c '[.issue.journals[]? | select(.notes != null and .notes != "")]')
    ORIG_DESC=$(jf '.issue.description')

    local assignee n i c cauthor cdate cnotes
    assignee=$(jf '.issue.assigned_to.name'); [ -n "$assignee" ] || assignee='—'
    n=$(printf '%s' "$COMMENTS_JSON" | jq 'length')

    term_size; cls
    h1 "Ticket #$id"; echo
    printf '  %s%s%s\n' "$BOLD" "$(trunc "$(jf '.issue.subject')" "$CW")" "$RST"; echo
    meta_row 'Status'   "$(jf '.issue.status.name')"   'Priorität'    "$(jf '.issue.priority.name')"
    meta_row 'Tracker'  "$(jf '.issue.tracker.name')"  'Projekt'      "$(jf '.issue.project.name')"
    meta_row 'Autor'    "$(jf '.issue.author.name')"   'Zugewiesen'   "$assignee"
    meta_row 'Erstellt' "$(fmt_date "$(jf '.issue.created_on')")" 'Aktualisiert' "$(fmt_date "$(jf '.issue.updated_on')")"
    echo
    h1 'Beschreibung'; echo
    para "$ORIG_DESC" 2 10; echo
    h1 "Kommentare ($n)"; echo
    [ "$n" -eq 0 ] && printf '  %s— keine —%s\n\n' "$GRY" "$RST"
    for ((i = 0; i < n && i < MAX_COMMENTS_TERM; i++)); do
        c=$(printf '%s' "$COMMENTS_JSON" | jq -c ".[$i]")
        cauthor=$(printf '%s' "$c" | jq -r '.user.name // "Unbekannt"')
        cdate=$(fmt_date "$(printf '%s' "$c" | jq -r '.created_on // ""')")
        cnotes=$(printf '%s' "$c" | jq -r '.notes')
        printf '  %s●%s %s%s%s %s· %s%s\n' "$MAG" "$RST" "$BOLD" "$cauthor" "$RST" "$GRY" "$cdate" "$RST"
        para "$cnotes" 4 4; echo
    done
    if [ "$n" -gt "$MAX_COMMENTS_TERM" ]; then
        printf '  %s… %d weitere – alle Kommentare stehen in voller Länge in der RTF%s\n\n' "$GRY" $((n - MAX_COMMENTS_TERM)) "$RST"
    fi
    rule
}

# ── Auf Änderung an der RTF warten (Spinner, q = abbrechen) ──────────────
wait_for_change() {
    local start frames i=0 key rc tick=1
    start=$(file_sig "$RTF_FILE")
    frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    [ "${BASH_VERSINFO[0]}" -ge 4 ] && tick=0.25
    hide_cursor
    while :; do
        if [ "$(file_sig "$RTF_FILE")" != "$start" ]; then
            show_cursor; printf '\r\033[2K'; return 0
        fi
        printf '\r  %s%s%s Warte auf Änderungen an %s%s%s … %s(q = abbrechen)%s' \
            "$CYN" "${frames[i]}" "$RST" "$BOLD" "$RTF_NAME" "$RST" "$GRY" "$RST"
        i=$(( (i + 1) % 10 ))
        key=""
        IFS= read -rs -n 1 -t "$tick" key; rc=$?
        if [ "$rc" -eq 0 ]; then
            case "$key" in q|Q) show_cursor; printf '\r\033[2K'; return 1 ;; esac
        elif [ "$rc" -le 128 ]; then
            sleep 1   # kein interaktives stdin → nicht heißlaufen
        fi
    done
}

# ── Synchronisieren ──────────────────────────────────────────────────────
sync_changes() {
    local txt new_desc orig_desc new_comment fields='{}' any=0 n i c cid orig new
    txt=$(rtf_to_text) || { err "RTF konnte nicht gelesen werden."; return 1; }

    new_desc=$(printf '%s\n' "$txt" | section 'BESCHREIBUNG' | norm)
    orig_desc=$(printf '%s\n' "$ORIG_DESC" | norm)
    new_comment=$(printf '%s\n' "$txt" | section 'NEUER KOMMENTAR' | norm)

    if ! printf '%s\n' "$txt" | grep -q '^==* BESCHREIBUNG ==*'; then
        warn "Marker „===== BESCHREIBUNG =====“ fehlt – Beschreibung bleibt unverändert."
    elif [ -z "$new_desc" ]; then
        warn "Beschreibung ist leer – bleibt unverändert."
    elif [ "$new_desc" != "$orig_desc" ]; then
        fields=$(printf '%s' "$fields" | jq --arg d "$new_desc" '. + {description: $d}'); any=1
    fi
    if [ -n "$new_comment" ]; then
        fields=$(printf '%s' "$fields" | jq --arg t "$new_comment" '. + {notes: $t}'); any=1
    fi
    if [ "$fields" != '{}' ]; then
        api PUT "/issues/$CUR_ID.json" "$(printf '%s' "$fields" | jq '{issue: .}')"
        if [ "$API_CODE" = 204 ] || [ "$API_CODE" = 200 ]; then
            printf '%s' "$fields" | jq -e 'has("description")' >/dev/null && ok "Beschreibung von #$CUR_ID aktualisiert."
            printf '%s' "$fields" | jq -e 'has("notes")' >/dev/null && ok "Neuer Kommentar zu #$CUR_ID hinzugefügt."
        else
            err "Ticket-Update fehlgeschlagen (HTTP $API_CODE)."; show_api_errors
        fi
    fi

    # Neue Kommentare mit Zeitstempel ("== KOMMENTAR TT.MM.JJJJ HH:MM ==") – anlegen und rückdatieren
    local blocks line dt body iso state=0 T=$'\t'
    blocks=$(printf '%s\n' "$txt" | extract_new_comments)
    if [ -n "$blocks" ]; then
        while IFS= read -r line; do
            case "$line" in
                "@@NEW@@${T}"*) dt=${line#"@@NEW@@${T}"}; body=""; state=1 ;;
                "@@END@@")
                    [ "$state" = 1 ] || continue
                    state=0
                    body=$(printf '%s' "$body" | norm)
                    if [ -z "$body" ]; then warn "Kommentar „${dt}“ ist leer – übersprungen."; continue; fi
                    any=1
                    if ! iso=$(to_iso_utc "$dt"); then
                        err "Kommentar „${dt}“: Zeitangabe nicht lesbar (erwartet TT.MM.JJJJ HH:MM) – nicht angelegt."; continue
                    fi
                    if ! create_comment "$body"; then
                        err "Kommentar „${dt}“ konnte nicht angelegt werden (HTTP $API_CODE)."; show_api_errors; continue
                    fi
                    if [ -z "$NEW_JOURNAL_ID" ]; then
                        warn "Kommentar „${dt}“ angelegt, aber ID nicht gefunden – Zeitstempel bleibt „jetzt“."
                    elif backdate_journal "$NEW_JOURNAL_ID" "$iso"; then
                        ok "Kommentar #$NEW_JOURNAL_ID angelegt und auf ${dt} datiert."
                    else
                        case "$API_CODE" in
                            403) warn "Kommentar #$NEW_JOURNAL_ID angelegt – Rückdatierung nicht aktiviert (Plugin-Einstellung „Backdating“)." ;;
                            404) warn "Kommentar #$NEW_JOURNAL_ID angelegt – Rückdatierung nicht verfügbar (redmine-extended-api fehlt)." ;;
                            *)   warn "Kommentar #$NEW_JOURNAL_ID angelegt – Rückdatierung fehlgeschlagen (HTTP $API_CODE)."; show_api_errors ;;
                        esac
                    fi ;;
                *) [ "$state" = 1 ] && body="${body}${line}"$'\n' ;;
            esac
        done <<EOF_BLOCKS
$blocks
EOF_BLOCKS
    fi

    n=$(printf '%s' "$COMMENTS_JSON" | jq 'length')
    for ((i = 0; i < n; i++)); do
        c=$(printf '%s' "$COMMENTS_JSON" | jq -c ".[$i]")
        cid=$(printf '%s' "$c" | jq -r '.id')
        orig=$(printf '%s' "$c" | jq -r '.notes' | norm)
        new=$(printf '%s\n' "$txt" | section "KOMMENTAR $cid" | norm)
        [ -n "$new" ] && [ "$new" != "$orig" ] || continue
        any=1
        api PUT "/journals/$cid.json" "$(jq -n --arg t "$new" '{journal: {notes: $t}}')"
        if [ "$API_CODE" = 204 ] || [ "$API_CODE" = 200 ]; then ok "Kommentar #$cid aktualisiert."
        else err "Kommentar #$cid konnte nicht aktualisiert werden (HTTP $API_CODE)."; show_api_errors; fi
    done
    [ "$any" = 1 ] || info "Keine inhaltlichen Änderungen gefunden – nichts synchronisiert."
    return 0
}

# ── Bearbeiten → Warten → ✔ → ENTER → Sync ───────────────────────────────
edit_cycle() {
    local key
    if ! write_rtf; then
        err "RTF konnte nicht geschrieben werden."; sleep 2; return
    fi
    open_file "$RTF_FILE" || warn "Kein Programm zum Öffnen gefunden – Datei manuell öffnen."
    echo
    info "RTF geschrieben: ${BOLD}${RTF_NAME}${RST} ${GRY}($SCRIPT_DIR)${RST} – im Standard-Editor geöffnet."
    printf '    %sText unter den ===== Markern ändern und speichern (⌘S) – die Änderung wird automatisch erkannt.%s\n\n' "$GRY" "$RST"

    if ! wait_for_change; then
        warn "Abgebrochen – zurück zur Startseite."; sleep 1; return
    fi
    printf '  %s%s✔  Änderung erkannt – bereit zum Synchronisieren%s\n' "$GRN" "$BOLD" "$RST"
    printf '     %sENTER%s  synchronisieren      %sq%s  abbrechen\n' "$BOLD" "$RST" "$BOLD" "$RST"
    printf '     %s(vorher in TextEdit speichern)%s\n  ' "$GRY" "$RST"
    IFS= read -r key || key=q
    case "$key" in q|Q) warn "Abgebrochen – RTF bleibt erhalten."; sleep 1; return ;; esac

    echo
    sync_changes
    init_rtf
    echo
    info "RTF geleert."
    printf '     %sENTER%s  zurück zur Startseite ' "$BOLD" "$RST"
    IFS= read -r key || true
}

main() {
    load_config
    check_connection
    init_rtf
    while :; do
        show_home
        [ -n "$TICKET_ID" ] || continue
        show_ticket "$TICKET_ID" || continue
        edit_cycle
    done
}

[ "${BASH_SOURCE[0]}" = "$0" ] && main
