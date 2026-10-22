#!/bin/bash
# Импорт всех туннелей из zip, выгруженного приложением WireGuard
# (меню «Export Tunnels to Zip…»), в /etc/wireguard.
# Использование: ./import-zip.sh ~/Desktop/wireguard-export.zip
set -euo pipefail

zip=${1:?Использование: $0 <файл.zip>}
[[ -f $zip ]] || { echo "Нет файла: $zip" >&2; exit 1; }

tmp=$(mktemp -d)
chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT
unzip -q -j "$zip" '*.conf' -d "$tmp"

# Кириллица -> латиница, прочие недопустимые символы -> «-», не длиннее 15 символов
sanitize() {
	printf '%s' "$1" | perl -CS -Mutf8 -pe '
		my %t = (а=>"a",б=>"b",в=>"v",г=>"g",д=>"d",е=>"e",ё=>"e",ж=>"zh",з=>"z",и=>"i",й=>"y",
			к=>"k",л=>"l",м=>"m",н=>"n",о=>"o",п=>"p",р=>"r",с=>"s",т=>"t",у=>"u",ф=>"f",х=>"h",
			ц=>"c",ч=>"ch",ш=>"sh",щ=>"sch",ъ=>"",ы=>"y",ь=>"",э=>"e",ю=>"yu",я=>"ya");
		s/(\p{Cyrillic})/my $c = $t{lc $1} \/\/ ""; $1 eq lc $1 ? $c : ucfirst $c/ge;
		s/[^a-zA-Z0-9_=+.-]+/-/g; s/^-+|-+$//g; $_ = substr($_, 0, 15); s/-+$//;'
}

sudo -v
sudo install -d -o root -g wheel -m 700 /etc/wireguard

shopt -s nullglob
for f in "$tmp"/*.conf; do
	orig=$(basename "$f" .conf)
	# wg-quick допускает только [a-zA-Z0-9_=+.-] и не больше 15 символов
	name=$(sanitize "$orig")
	[[ -n $name ]] || name=tunnel
	base=$name i=2
	while sudo test -e "/etc/wireguard/$name.conf"; do
		if sudo cmp -s "$f" "/etc/wireguard/$name.conf"; then break; fi
		name="${base:0:13}-$i"; i=$((i + 1))
	done

	sudo install -o root -g wheel -m 600 "$f" "/etc/wireguard/$name.conf"

	notes=()
	grep -qiE '^\s*DNS\s*=' "$f" && notes+=("есть DNS")
	grep -qE '0\.0\.0\.0/0|::/0' "$f" && notes+=("весь трафик 0.0.0.0/0")
	label=$name; [[ $name != "$orig" ]] && label="$name  (было: $orig)"
	if ((${#notes[@]})); then
		echo "✓ $label  ⚠ $(IFS=,; echo "${notes[*]}")"
	else
		echo "✓ $label"
	fi
done

echo
echo "Готово. Zip содержит приватные ключи — удалите его: rm \"$zip\""
