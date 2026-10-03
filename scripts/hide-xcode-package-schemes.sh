#!/bin/sh
set -eu

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
project_dir="$repo_root/Translatis.xcodeproj"
user_name="${USER:-$(id -un)}"
scheme_dir="$project_dir/xcuserdata/$user_name.xcuserdatad/xcschemes"
plist="$scheme_dir/xcschememanagement.plist"

mkdir -p "$scheme_dir"

cat > "$plist" <<'PLIST_HEADER'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SchemeUserState</key>
	<dict>
		<key>TranslatisMac.xcscheme_^#shared#^_</key>
		<dict>
			<key>isShown</key>
			<true/>
			<key>orderHint</key>
			<integer>0</integer>
		</dict>
		<key>TranslatisiOS.xcscheme_^#shared#^_</key>
		<dict>
			<key>isShown</key>
			<true/>
			<key>orderHint</key>
			<integer>1</integer>
		</dict>
		<key>translatis.xcscheme</key>
		<dict>
			<key>isShown</key>
			<true/>
			<key>orderHint</key>
			<integer>2</integer>
		</dict>
		<key>translatis.xcscheme_^#shared#^_</key>
		<dict>
			<key>isShown</key>
			<true/>
			<key>orderHint</key>
			<integer>2</integer>
		</dict>
PLIST_HEADER

for scheme in \
	IntatisCore \
	IntatisProtocol \
	IntatisProviders \
	IntatisConversation \
	IntatisArtifacts \
	IntatisMultimodal \
	IntatisSharedUI \
	IntatisTools \
	IntatisPermission \
	IntatisAgentKernel \
	IntatisCowork
do
	cat >> "$plist" <<PLIST_SCHEME
		<key>$scheme.xcscheme</key>
		<dict>
			<key>isShown</key>
			<false/>
		</dict>
		<key>$scheme.xcscheme_^#shared#^_</key>
		<dict>
			<key>isShown</key>
			<false/>
		</dict>
PLIST_SCHEME
done

cat >> "$plist" <<'PLIST_FOOTER'
	</dict>
</dict>
</plist>
PLIST_FOOTER
