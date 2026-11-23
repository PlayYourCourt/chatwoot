#!/usr/bin/env bash
# Load the Salesforce weekly-export ZIPs into the sf-staging Postgres (schema `sf`, one text column per
# CSV column, lower-cased names). Streams straight out of the ZIPs: nothing is unpacked to disk.
#   deploy/salesforce/load_staging.sh "sales_force_exports/nov 6"
# Re-running truncates and reloads each table. EmailMessage is split across two ZIPs (both have
# headers); every part is appended to the same table.
set -euo pipefail
ZIP_DIR=${1:?usage: load_staging.sh ZIP_DIR}
PSQL=(docker exec -i -e PGOPTIONS='-c client_min_messages=warning' sf-staging psql -v ON_ERROR_STOP=1 -U sf -d sf -q)

# csv name -> table name
declare -A TABLES=(
  [Account.csv]=account
  [Contact.csv]=contact
  [Lead.csv]=lead
  [Case.csv]="case"
  [EmailMessage.csv]=email_message
  [Opportunity.csv]=opportunity
  [Staging__c.csv]=staging
  [Legacy_Notes__c.csv]=legacy_note
  [ContentVersion.csv]=content_version              # enhanced notes (FileType SNOTE) live here, with files
  [ContentDocumentLink.csv]=content_document_link   # ...and this links them to Accounts / Opportunities / Leads
  [TABYOT__Text_Anything_Interaction__c.csv]=interaction
  [TABYOT__Text_Anything_Interaction_Media__c.csv]=interaction_media
  [TABYOT__Text_Anything_Purchased_Number__c.csv]=purchased_number
  [User.csv]=sf_user
  [RecordType.csv]=record_type
)

"${PSQL[@]}" -c 'CREATE SCHEMA IF NOT EXISTS sf;'

header_ddl() { # reads the header line of a CSV on stdin, prints a CREATE TABLE
  python3 -I -c '
import csv, sys
raw = sys.stdin.buffer
cols = next(csv.reader([raw.readline().decode("utf-8", "replace")]))
raw.read()  # drain the rest so `head` is not killed by SIGPIPE
defs = ", ".join(f"\"{c.lower()}\" text" for c in cols)
print(f"DROP TABLE IF EXISTS sf.\"{sys.argv[1]}\" CASCADE; CREATE TABLE sf.\"{sys.argv[1]}\" ({defs});")' "$1"
}

for csv in "${!TABLES[@]}"; do
  table=${TABLES[$csv]}
  # ONLY=table1,table2 restricts the run (re-load a single table).
  if [ -n "${ONLY:-}" ] && [[ ",$ONLY," != *",$table,"* ]]; then continue; fi
  mapfile -t parts < <(for z in "$ZIP_DIR"/*.ZIP; do unzip -l "$z" | awk -v f="$csv" '$4 == f {found=1} END {exit !found}' && echo "$z"; done)
  if [ ${#parts[@]} -eq 0 ]; then echo "skip $csv (not in export)"; continue; fi
  echo "== $table  <- $csv (${#parts[@]} part(s))"
  # `|| true`: head closes the pipe early and unzip exits 141 under pipefail.
  { unzip -p "${parts[0]}" "$csv" 2>/dev/null || true; } | head -c 1000000 | header_ddl "$table" | "${PSQL[@]}"
  for z in "${parts[@]}"; do
    # tr strips NUL bytes (present in interaction bodies); iconv drops invalid UTF-8 sequences.
    unzip -p "$z" "$csv" | tr -d '\000' | iconv -f utf-8 -t utf-8 -c \
      | "${PSQL[@]}" -c "\\copy sf.\"$table\" FROM STDIN WITH (FORMAT csv, HEADER true)"
  done
  "${PSQL[@]}" -tAc "SELECT '   rows: ' || count(*) FROM sf.\"$table\";"
done

# Enhanced-note bodies. An export made with "Include Salesforce Files and Salesforce CRM Content document
# versions" ticked carries every ContentVersion as a file inside the ZIPs, at the path in its VersionData
# column; the note bodies (FileType SNOTE, small HTML) are read from there into sf.content_note_body. Without
# that option the column is absent and the transform falls back to the 255-character TextPreview.
if [ -z "${ONLY:-}" ] || [[ ",$ONLY," == *",content_version,"* ]]; then
  has_files=$("${PSQL[@]}" -tAc "SELECT count(*) FROM information_schema.columns
    WHERE table_schema = 'sf' AND table_name = 'content_version' AND column_name = 'versiondata';")
  "${PSQL[@]}" -c 'DROP TABLE IF EXISTS sf.content_note_body; CREATE TABLE sf.content_note_body (id text PRIMARY KEY, body text);'
  if [ "$has_files" = "1" ]; then
    echo "== content_note_body <- ContentVersion files"
    read -r -d '' NOTE_BODIES <<'PY' || true
import csv, sys, zipfile
members = {}
for path in sys.argv[1:]:
    archive = zipfile.ZipFile(path)
    for name in archive.namelist():
        members.setdefault(name, archive)
out = csv.writer(sys.stdout)
missing = 0
for note_id, member in csv.reader(sys.stdin):
    archive = members.get(member) or members.get(member.lstrip('/'))
    if archive is None:
        missing += 1
        continue
    out.writerow([note_id, archive.read(member).decode('utf-8', 'replace').replace('\0', '')])
print(f'   note bodies missing from the ZIPs: {missing}', file=sys.stderr)
PY
    "${PSQL[@]}" -c "\\copy (SELECT id, versiondata FROM sf.content_version WHERE filetype = 'SNOTE' AND islatest = '1') TO STDOUT WITH (FORMAT csv)" \
      | python3 -I -c "$NOTE_BODIES" "$ZIP_DIR"/*.ZIP \
      | "${PSQL[@]}" -c "\\copy sf.content_note_body FROM STDIN WITH (FORMAT csv)"
  else
    echo "skip content_note_body (export has no files; note bodies fall back to TextPreview)"
  fi
  "${PSQL[@]}" -tAc "SELECT '   rows: ' || count(*) FROM sf.content_note_body;"
fi
echo "load complete"
