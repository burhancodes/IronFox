#!/bin/bash

arch=${1:-arm64-v8a}
data=$(curl -s https://gitlab.com/api/v4/projects/ironfox-oss%2FIronFox/releases | jq -r '.[0]')
apk=$(echo "$data" | jq -r '.assets.links[] | select(.name | endswith("'"-$arch.apk"'")) | .url')
wget -q "$apk" -O latest.apk

wget -q https://bitbucket.org/iBotPeaches/apktool/downloads/apktool_2.12.1.jar -O apktool.jar
wget -q https://raw.githubusercontent.com/iBotPeaches/Apktool/master/scripts/linux/apktool
chmod +x apktool*

rm -rf patched patched_signed.apk
./apktool d latest.apk -o patched
rm -rf patched/META-INF

# Patch values-night colors
sed -i 's/<color name="fx_mobile_layer_color_1">.*/<color name="fx_mobile_layer_color_1">#ff1e1e2e<\/color>/g' patched/res/values-night/colors.xml
sed -i 's/<color name="fx_mobile_layer_color_2">.*/<color name="fx_mobile_layer_color_2">@color\/photonDarkGrey90<\/color>/g' patched/res/values-night/colors.xml
sed -i 's/<color name="fx_mobile_action_color_secondary">.*/<color name="fx_mobile_action_color_secondary">#ff313244<\/color>/g' patched/res/values-night/colors.xml
sed -i 's/<color name="button_material_dark">.*/<color name="button_material_dark">#ff313244<\/color>/g' patched/res/values/colors.xml

# Patch PhotonColors.smali - DarkGrey colors to Catppuccin Mocha
sed -i 's/ff5b5b66/ff313244/g' patched/smali*/mozilla/components/ui/colors/PhotonColors.smali
sed -i 's/ff52525e/ff1e1e2e/g' patched/smali*/mozilla/components/ui/colors/PhotonColors.smali
sed -i 's/ff42414d/ff1e1e2e/g' patched/smali*/mozilla/components/ui/colors/PhotonColors.smali
sed -i 's/ff2b2a33/ff11111b/g' patched/smali*/mozilla/components/ui/colors/PhotonColors.smali
sed -i 's/ff1c1b22/ff1e1e2e/g' patched/smali*/mozilla/components/ui/colors/PhotonColors.smali

photon_color_files=(
	"patched/res/values/colors.xml"
	"patched/res/values/photon_colors.xml"
)

for file in "${photon_color_files[@]}"; do
	[ -f "$file" ] || continue
	sed -i 's/#f9f9fa/#bac2de/g' "$file"
	sed -i 's/#ededf0/#a6adc8/g' "$file"
	sed -i 's/#d7d7db/#6c7086/g' "$file"
	sed -i 's/#b1b1b3/#585b70/g' "$file"
	sed -i 's/#737373/#45475a/g' "$file"
	sed -i 's/#4a4a4f/#313244/g' "$file"
	sed -i 's/#38383d/#1e1e2e/g' "$file"
	sed -i 's/#2a2a2e/#181825/g' "$file"
	sed -i 's/#0c0c0d/#11111b/g' "$file"
	sed -i 's/#ff5b5b66/#ffbac2de/g' "$file"
	sed -i 's/#735b5b66/#ff6c7086/g' "$file"
	sed -i 's/#ff52525e/#ff585b70/g' "$file"
	sed -i 's/#ff4a4a55/#ff45475a/g' "$file"
	sed -i 's/#ff42414d/#ff1e1e2e/g' "$file"
	sed -i 's/#f242414d/#ff313244/g' "$file"
	sed -i 's/#f542414d/#ff313244/g' "$file"
	sed -i 's/#ff3a3944/#ff313244/g' "$file"
	sed -i 's/#ff32313c/#ff1e1e2e/g' "$file"
	sed -i 's/#ff2b2a33/#ff11111b/g' "$file"
	sed -i 's/#ff23222b/#ff181825/g' "$file"
	sed -i 's/#ff1c1b22/#ff0c0c12/g' "$file"
	sed -i 's/#ff15141a/#ff11111b/g' "$file"
	sed -i 's/#6615141a/#ff11111b/g' "$file"
	sed -i 's/#8015141a/#ff11111b/g' "$file"
	sed -i 's/#9915141a/#ff11111b/g' "$file"
	sed -i 's/#f215141a/#ff11111b/g' "$file"
	sed -i 's/#f515141a/#ff11111b/g' "$file"
done

# Patch readerview.css
sed -i 's/1c1b22/1e1e2e/g' patched/assets/extensions/readerview/readerview.css
sed -i 's/eeeeee/cdd6f4/g' patched/assets/extensions/readerview/readerview.css
sed -i 's/mipmap\/ic_launcher_round/drawable\/ic_launcher_foreground/g' patched/res/drawable/splash_screen.xml
sed -i 's/160\.0dip/200\.0dip/g' patched/res/drawable/splash_screen.xml

./apktool b patched -o patched.apk

zipalign 4 patched.apk patched_signed.apk
rm -rf patched patched.apk
