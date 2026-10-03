#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_root="$(cd "$script_dir/.." && pwd -P)"
spec="$project_root/Packages/IntatisTools/Runtime/document-runtime/release-spec.json"
runtime_root="${1:-}"
expected_architecture="${2:-}"
expected_signing_identity="${3:-}"
validation_mode="${4:-static}"
temporary_root=""

fail() {
    print -u2 -- "error: $*"
    exit 1
}

cleanup() {
    if [[ -n "${temporary_root:-}" && -d "$temporary_root" ]]; then
        /bin/rm -rf -- "$temporary_root"
    fi
}
trap cleanup EXIT

[[ -n "$runtime_root" && -n "$expected_architecture" ]] \
    || fail "usage: scripts/validate-document-runtime.sh <runtime-root> <arm64|x86_64> [Developer ID identity|-] [static|execute|execute-local]"
[[ "$expected_architecture" == "arm64" || "$expected_architecture" == "x86_64" ]] \
    || fail "runtime architecture must be arm64 or x86_64"
[[ "$validation_mode" == "static" || "$validation_mode" == "execute" \
    || "$validation_mode" == "execute-local" ]] \
    || fail "validation mode must be static, execute, or execute-local"
[[ "$runtime_root" == /* ]] || fail "runtime root must be an absolute path"
[[ -d "$runtime_root" && ! -L "$runtime_root" ]] || fail "runtime root is missing or is a symlink"
runtime_root="$(cd "$runtime_root" && pwd -P)"

manifest="$runtime_root/runtime-manifest.json"
inventory="$runtime_root/SHA256SUMS.txt"
[[ -f "$spec" && ! -L "$spec" ]] || fail "repository document runtime release spec is missing"
[[ -f "$manifest" && ! -L "$manifest" ]] || fail "runtime manifest is missing or unsafe"
[[ -f "$inventory" && ! -L "$inventory" ]] || fail "runtime SHA-256 inventory is missing or unsafe"
/usr/bin/plutil -convert xml1 -o /dev/null "$spec" \
    || fail "repository document runtime release spec is not valid JSON"
/usr/bin/plutil -convert xml1 -o /dev/null "$manifest" \
    || fail "runtime manifest is not valid JSON"

json_value() {
    /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null \
        || fail "missing JSON field $2 in ${1:t}"
}

for key in schema_version layout_version runtime_release maximum_resident_bytes; do
    [[ "$(json_value "$manifest" "$key")" == "$(json_value "$spec" "$key")" ]] \
        || fail "runtime manifest $key does not match the release spec"
done
[[ "$(json_value "$manifest" architecture)" == "$expected_architecture" ]] \
    || fail "runtime manifest architecture does not match $expected_architecture"
/usr/bin/cmp -s \
    <(/usr/bin/jq -S . "$spec") \
    <(/usr/bin/jq -S 'del(.architecture, .python_lock_sha256)' "$manifest") \
    || fail "runtime manifest does not preserve the exact repository release spec"

components=(
    python docling docling_slim docling_core docling_parse python_docx
    python_pptx openpyxl lxml pypdfium2 tesseract tessdata_fast tectonic
    libreoffice docling_layout_model leptonica libpng numpy torch torchvision
)
for component in $components; do
    [[ "$(json_value "$manifest" "components.$component")" \
        == "$(json_value "$spec" "components.$component")" ]] \
        || fail "runtime component $component does not match the release spec"
done

required_files=(
    bin/python3
    bin/tesseract
    bin/tectonic
    models/docling/docling-project--docling-layout-heron/config.json
    models/docling/docling-project--docling-layout-heron/model.safetensors
    models/docling/docling-project--docling-layout-heron/preprocessor_config.json
    share/tessdata/eng.traineddata
    ThirdPartyNotices/runtime.spdx.json
    ThirdPartyNotices/LICENSES.txt
    "ThirdPartyNotices/python-lock-$expected_architecture.txt"
)
for relative_path in $required_files; do
    [[ -f "$runtime_root/$relative_path" && ! -L "$runtime_root/$relative_path" ]] \
        || fail "runtime is missing required regular file $relative_path"
done
repository_python_lock="$project_root/Packages/IntatisTools/Runtime/document-runtime/python-lock-$expected_architecture.txt"
runtime_python_lock="$runtime_root/ThirdPartyNotices/python-lock-$expected_architecture.txt"
[[ -f "$repository_python_lock" && ! -L "$repository_python_lock" ]] \
    || fail "repository Python wheel lock is missing or unsafe"
repository_python_lock_sha="$(/usr/bin/shasum -a 256 "$repository_python_lock" \
    | /usr/bin/awk '{print $1}')"
runtime_python_lock_sha="$(/usr/bin/shasum -a 256 "$runtime_python_lock" \
    | /usr/bin/awk '{print $1}')"
[[ "$(json_value "$manifest" python_lock_sha256)" == "$repository_python_lock_sha" \
    && "$runtime_python_lock_sha" == "$repository_python_lock_sha" ]] \
    || fail "runtime Python wheel lock does not match the repository contract"
required_directories=(
    python/Python.framework/Versions/3.11
    models/docling
    share/tessdata
    share/tectonic/cache
    ThirdPartyNotices/licenses
    libreoffice/26.8.0.0.beta1/LibreOffice.app
)
for relative_path in $required_directories; do
    [[ -d "$runtime_root/$relative_path" && ! -L "$runtime_root/$relative_path" ]] \
        || fail "runtime is missing required directory $relative_path"
done
for executable in \
    bin/python3 \
    bin/tesseract \
    bin/tectonic; do
    [[ -x "$runtime_root/$executable" ]] || fail "runtime executable is not executable: $executable"
done
runtime_spdx="$runtime_root/ThirdPartyNotices/runtime.spdx.json"
/usr/bin/plutil -convert xml1 -o /dev/null "$runtime_spdx" \
    || fail "runtime SPDX SBOM is not valid JSON"
[[ "$(json_value "$runtime_spdx" spdxVersion)" == "SPDX-2.3" ]] \
    || fail "runtime SBOM must use SPDX-2.3"
[[ "$(json_value "$runtime_spdx" dataLicense)" == "CC0-1.0" ]] \
    || fail "runtime SBOM dataLicense must be CC0-1.0"
[[ "$(json_value "$runtime_spdx" SPDXID)" == "SPDXRef-DOCUMENT" ]] \
    || fail "runtime SBOM must identify the document as SPDXRef-DOCUMENT"
[[ -n "$(json_value "$runtime_spdx" documentNamespace)" ]] \
    || fail "runtime SBOM has no document namespace"
spdx_package_count="$(
    /usr/bin/plutil -extract packages raw -expect array -o - "$runtime_spdx" 2>/dev/null
)" || fail "runtime SBOM packages field is missing or is not an array"
[[ "$spdx_package_count" == <-> && "$spdx_package_count" -gt 0 ]] \
    || fail "runtime SBOM contains no packages"
[[ -s "$runtime_root/ThirdPartyNotices/LICENSES.txt" ]] \
    || fail "runtime license inventory is empty"
[[ -n "$(/usr/bin/find "$runtime_root/ThirdPartyNotices/licenses" -type f -print -quit)" ]] \
    || fail "runtime license-text directory is empty"
[[ -n "$(/usr/bin/find "$runtime_root/share/tectonic/cache" -type f -print -quit)" ]] \
    || fail "Tectonic offline cache is empty"

while IFS= read -r link; do
    resolved="$(/bin/realpath "$link")" || fail "runtime symlink cannot be resolved: $link"
    case "$resolved" in
        "$runtime_root"/*) ;;
        *) fail "runtime symlink escapes its architecture root: $link" ;;
    esac
done < <(/usr/bin/find "$runtime_root" -type l -print)

temporary_root="$(/usr/bin/mktemp -d /private/tmp/translatis-runtime-validation.XXXXXX)"
/bin/chmod 0700 "$temporary_root"
actual_paths="$temporary_root/actual-paths.txt"
inventory_paths="$temporary_root/inventory-paths.txt"
(
    cd "$runtime_root"
    /usr/bin/find . -type f ! -path './SHA256SUMS.txt' -print | LC_ALL=C /usr/bin/sort > "$actual_paths"
)

: > "$inventory_paths"
while IFS= read -r line; do
    [[ "$line" =~ '^[0-9a-f]{64}  \./[^/].*$' ]] \
        || fail "runtime inventory contains a malformed entry"
    relative_path="${line[67,-1]}"
    [[ "$relative_path" != *$'\n'* && "$relative_path" != *$'\r'* ]] \
        || fail "runtime inventory contains an unsafe filename"
    print -r -- "$relative_path" >> "$inventory_paths"
done < "$inventory"
LC_ALL=C /usr/bin/sort -u -o "$inventory_paths" "$inventory_paths"
/usr/bin/cmp -s "$actual_paths" "$inventory_paths" \
    || fail "runtime SHA-256 inventory is incomplete or lists unknown files"
(
    cd "$runtime_root"
    /usr/bin/shasum -a 256 --check SHA256SUMS.txt >/dev/null
) || fail "runtime SHA-256 inventory verification failed"

expected_model_paths=$'./config.json\n./model.safetensors\n./preprocessor_config.json'
actual_model_paths="$(
    cd "$runtime_root/models/docling/docling-project--docling-layout-heron"
    /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort
)"
[[ "$actual_model_paths" == "$expected_model_paths" ]] \
    || fail "Docling layout model directory does not match the fixed release set"
[[ -z "$(/usr/bin/find \
    "$runtime_root/models/docling/docling-project--docling-layout-heron" \
    -type l -print -quit)" ]] \
    || fail "Docling layout model directory must not contain symlinks"

expected_tessdata_paths='./eng.traineddata'
actual_tessdata_paths="$(
    cd "$runtime_root/share/tessdata"
    /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort
)"
[[ "$actual_tessdata_paths" == "$expected_tessdata_paths" ]] \
    || fail "Tesseract data directory does not match the fixed allowlist"
[[ -z "$(/usr/bin/find "$runtime_root/share/tessdata" -type l -print -quit)" ]] \
    || fail "Tesseract data directory must not contain symlinks"

artifact_checks=(
    'artifact_sha256.docling_layout_model.config_json|models/docling/docling-project--docling-layout-heron/config.json'
    'artifact_sha256.docling_layout_model.model_safetensors|models/docling/docling-project--docling-layout-heron/model.safetensors'
    'artifact_sha256.docling_layout_model.preprocessor_config_json|models/docling/docling-project--docling-layout-heron/preprocessor_config.json'
    'artifact_sha256.tessdata.eng|share/tessdata/eng.traineddata'
)
for artifact_check in $artifact_checks; do
    spec_key="${artifact_check%%|*}"
    relative_path="${artifact_check#*|}"
    expected_digest="$(json_value "$spec" "$spec_key")"
    actual_digest="$(/usr/bin/shasum -a 256 "$runtime_root/$relative_path" | /usr/bin/awk '{print $1}')"
    [[ "$actual_digest" == "$expected_digest" ]] \
        || fail "runtime artifact digest does not match the release spec: $relative_path"
done

macho_inspection_index=0
while IFS= read -r candidate; do
    file_description="$(/usr/bin/file -b "$candidate")"
    [[ "$file_description" == *"Mach-O"* ]] || continue
    macho_inspection_index=$((macho_inspection_index + 1))
    inspection_candidate="$candidate"
    if [[ "$candidate" == *'('* || "$candidate" == *')'* ]]; then
        inspection_candidate="$temporary_root/macho-inspection-$macho_inspection_index"
        /bin/ln -s "$candidate" "$inspection_candidate"
    fi
    architectures="$(/usr/bin/lipo -archs "$candidate")" \
        || fail "could not inspect Mach-O architecture: $candidate"
    [[ " $architectures " == *" $expected_architecture "* ]] \
        || fail "Mach-O file is missing $expected_architecture: $candidate"
    linked_libraries="$(/usr/bin/otool -L "$inspection_candidate")" \
        || fail "could not inspect Mach-O dependencies: $candidate"
    install_name="$(/usr/bin/otool -D "$inspection_candidate" 2>/dev/null \
        | /usr/bin/awk 'NR == 2 { print; exit }')"
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        [[ -z "$install_name" || "$dependency" != "$install_name" ]] || continue
        case "$dependency" in
            /System/Library/*|/usr/lib/*|@loader_path/*|@executable_path/*|@rpath/*)
                ;;
            *)
                fail "Mach-O has a non-system, non-bundle-relative dependency: $candidate -> $dependency"
                ;;
        esac
    done < <(print -r -- "$linked_libraries" | /usr/bin/awk 'NR > 1 { print $1 }')
    load_commands="$(/usr/bin/otool -l "$inspection_candidate")" \
        || fail "could not inspect Mach-O load commands: $candidate"
    while IFS= read -r runtime_search_path; do
        [[ -n "$runtime_search_path" ]] || continue
        case "$runtime_search_path" in
            /System/Library/*|/usr/lib/*|@loader_path|@loader_path/*|\
            @executable_path|@executable_path/*)
                ;;
            *)
                fail "Mach-O has a non-system, non-bundle-relative LC_RPATH: $candidate -> $runtime_search_path"
                ;;
        esac
    done < <(print -r -- "$load_commands" | /usr/bin/awk '
        $1 == "cmd" && $2 == "LC_RPATH" { awaiting_path = 1; next }
        awaiting_path && $1 == "path" { print $2; awaiting_path = 0 }
    ')
    signable_macho=0
    case "$file_description" in
        *Mach-O*executable*|*Mach-O*'dynamically linked shared library'*|*Mach-O*bundle*)
            signable_macho=1
            ;;
    esac
    if [[ -n "$expected_signing_identity" && "$signable_macho" == "1" ]]; then
        /usr/bin/codesign --verify --strict "$candidate" >/dev/null 2>&1 \
            || fail "runtime Mach-O has no valid strict signature: $candidate"
        signature_info="$(/usr/bin/codesign -dv --verbose=4 "$candidate" 2>&1)"
        if [[ "$expected_signing_identity" == "-" ]]; then
            [[ "$signature_info" == *"Signature=adhoc"* ]] \
                || fail "runtime Mach-O is not ad-hoc signed: $candidate"
        else
            [[ "$signature_info" == *"Authority=$expected_signing_identity"* ]] \
                || fail "runtime Mach-O is not signed by the selected Developer ID identity: $candidate"
        fi
    fi
done < <(/usr/bin/find "$runtime_root" -type f \
    \( -perm -111 -o -name '*.so' -o -name '*.dylib*' \
       -o -name '*.jnilib' -o -name '*.bundle' -o -name '*.a' \
       -o -name '*.o' \) -print)

if [[ "$validation_mode" != "static" ]]; then
    if [[ "$validation_mode" == "execute" ]]; then
        [[ -n "$expected_signing_identity" && "$expected_signing_identity" != "-" ]] \
            || fail "execute validation requires an exact Developer ID identity"
    else
        [[ "$expected_signing_identity" == "-" ]] \
            || fail "execute-local validation requires the ad-hoc identity marker '-'"
    fi
    sealed_app="$(cd "$runtime_root/../../../.." && pwd -P)"
    [[ "$sealed_app" == *.app \
        && "$runtime_root" == "$sealed_app/Contents/Resources/DocumentRuntime/$expected_architecture" ]] \
        || fail "execute validation is allowed only for a runtime sealed inside its final App"
    /usr/bin/codesign --verify --deep --strict "$sealed_app" >/dev/null 2>&1 \
        || fail "execute validation requires a valid outer App resource seal"
    sealed_app_signature="$(/usr/bin/codesign -dv --verbose=4 "$sealed_app" 2>&1)"
    [[ "$sealed_app_signature" == *"runtime"* ]] \
        || fail "outer App is missing Hardened Runtime"
    if [[ "$validation_mode" == "execute" ]]; then
        [[ "$sealed_app_signature" == *"Authority=$expected_signing_identity"* ]] \
            || fail "outer App is not signed by the selected Developer ID identity"
    else
        [[ "$sealed_app_signature" == *"Signature=adhoc"* ]] \
            || fail "outer App is not ad-hoc signed"
    fi

    /bin/mkdir -p "$temporary_root/home" "$temporary_root/tmp"
    /bin/chmod 0700 "$temporary_root/home" "$temporary_root/tmp"

    run_for_architecture() {
        /usr/bin/env -i \
            HOME="$temporary_root/home" \
            TMPDIR="$temporary_root/tmp/" \
            PATH=/usr/bin:/bin \
            LANG=C \
            LC_ALL=C \
            /usr/bin/arch -"$expected_architecture" "$@"
    }

    run_python_for_architecture() {
        /usr/bin/env -i \
            HOME="$temporary_root/home" \
            TMPDIR="$temporary_root/tmp/" \
            PATH=/usr/bin:/bin \
            LANG=C \
            LC_ALL=C \
            PYTHONHOME="$runtime_root/python/Python.framework/Versions/3.11" \
            PYTHONNOUSERSITE=1 \
            PYTHONDONTWRITEBYTECODE=1 \
            HF_HUB_OFFLINE=1 \
            TRANSFORMERS_OFFLINE=1 \
            /usr/bin/arch -"$expected_architecture" "$@"
    }

    expected_python_versions=$'python=3.11.9\ndocling=2.117.0\ndocling-slim=2.117.0\ndocling-core=2.89.0\ndocling-parse=7.8.1\npython-docx=1.2.0\npython-pptx=1.0.2\nopenpyxl=3.1.5\nlxml=6.1.1\npypdfium2=5.12.1\nnumpy=1.26.4\ntorch=2.2.2\ntorchvision=0.17.2'
    actual_python_versions="$(
        run_python_for_architecture "$runtime_root/bin/python3" -I -B -c \
            'import importlib.metadata as m, platform; names=["docling","docling-slim","docling-core","docling-parse","python-docx","python-pptx","openpyxl","lxml","pypdfium2","numpy","torch","torchvision"]; print("python="+platform.python_version()); [print(name+"="+m.version(name)) for name in names]'
    )" || fail "runtime Python dependency inspection failed"
    [[ "$actual_python_versions" == "$expected_python_versions" ]] \
        || fail "runtime Python dependency versions do not match the release spec"

    tesseract_version="$(run_for_architecture "$runtime_root/bin/tesseract" --version 2>&1)" \
        || fail "runtime Tesseract version inspection failed"
    [[ "${tesseract_version%%$'\n'*}" == "tesseract 5.5.3" ]] \
        || fail "runtime Tesseract version does not match the release spec"

    tectonic_version="$(
        run_for_architecture "$runtime_root/bin/tectonic" --version 2>&1
    )" || fail "runtime Tectonic version inspection failed"
    # The fixed upstream 0.15.0 macOS asset emits its Cargo package version
    # followed immediately by its branded display version on the same stdout
    # line. Require that exact output; do not lower this to a substring match.
    [[ "$tectonic_version" == 'tectonic 0.15.0Tectonic 0.15.0' ]] \
        || fail "runtime Tectonic version does not match the release spec"

    libreoffice_version="$(
        run_for_architecture \
            "$runtime_root/libreoffice/26.8.0.0.beta1/LibreOffice.app/Contents/MacOS/soffice" \
            --version 2>&1
    )" || fail "runtime LibreOffice version inspection failed"
    [[ "${libreoffice_version%%$'\n'*}" == 'LibreOfficeDev 26.8.0.0.beta1'* ]] \
        || fail "runtime LibreOffice version does not match the release spec"

    document_smoke_root="$temporary_root/document-smoke"
    /bin/mkdir -p \
        "$document_smoke_root/libreoffice-output" \
        "$document_smoke_root/tectonic-output"
    smoke_docx="$document_smoke_root/runtime.docx"
    run_python_for_architecture "$runtime_root/bin/python3" -I -B -c '
from docx import Document
import sys
document = Document()
document.add_paragraph("TRANSLATIS DOCUMENT RUNTIME 48291")
document.save(sys.argv[1])
' "$smoke_docx" || fail "fixed python-docx write smoke failed"
    docling_docx_smoke="$(
        run_python_for_architecture "$runtime_root/bin/python3" -I -B -c '
from docling.datamodel.backend_options import MsWordBackendOptions
from docling.datamodel.base_models import ConversionStatus, InputFormat
from docling.datamodel.pipeline_options import ConvertPipelineOptions
from docling.document_converter import DocumentConverter, WordFormatOption
import sys
options = ConvertPipelineOptions(
    document_timeout=60.0,
    enable_remote_services=False,
    allow_external_plugins=False,
    do_picture_classification=False,
    do_picture_description=False,
    do_chart_extraction=False,
)
converter = DocumentConverter(
    allowed_formats=[InputFormat.DOCX],
    format_options={InputFormat.DOCX: WordFormatOption(
        pipeline_options=options,
        backend_options=MsWordBackendOptions(
            enable_remote_fetch=False,
            enable_local_fetch=False,
            render_chart_images=False,
        ),
    )},
)
conversion = converter.convert(sys.argv[1], raises_on_error=True)
assert conversion.status == ConversionStatus.SUCCESS and not conversion.errors
assert "TRANSLATIS DOCUMENT RUNTIME 48291" in conversion.document.export_to_markdown()
print("docx-ok")
' "$smoke_docx"
    )" || fail "fixed Docling DOCX conversion smoke failed"
    [[ "${docling_docx_smoke##*$'\n'}" == "docx-ok" ]] \
        || fail "fixed Docling DOCX conversion returned unexpected output"

    libreoffice_profile="$document_smoke_root/libreoffice-profile"
    /bin/mkdir -p "$libreoffice_profile"
    run_for_architecture \
        "$runtime_root/libreoffice/26.8.0.0.beta1/LibreOffice.app/Contents/MacOS/soffice" \
        "-env:UserInstallation=file://$libreoffice_profile" \
        --headless --convert-to pdf \
        --outdir "$document_smoke_root/libreoffice-output" \
        "$smoke_docx" >/dev/null 2>&1 \
        || fail "fixed LibreOffice DOCX-to-PDF smoke failed"
    [[ -s "$document_smoke_root/libreoffice-output/runtime.pdf" ]] \
        || fail "fixed LibreOffice smoke produced no PDF"

    smoke_image="$document_smoke_root/ocr.png"
    run_python_for_architecture "$runtime_root/bin/python3" -I -B -c '
from PIL import Image, ImageDraw, ImageFont
import sys
image = Image.new("RGB", (1200, 180), "white")
font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 64)
ImageDraw.Draw(image).text((30, 45), "TRANSLATIS RUNTIME 48291", fill="black", font=font)
image.save(sys.argv[1])
' "$smoke_image" || fail "fixed Pillow OCR fixture creation failed"
    tesseract_smoke="$(
        run_for_architecture "$runtime_root/bin/tesseract" \
            "$smoke_image" stdout \
            --tessdata-dir "$runtime_root/share/tessdata" \
            -l eng --psm 7 2>/dev/null
    )" || fail "fixed Tesseract OCR smoke failed"
    normalized_tesseract="$(
        print -r -- "$tesseract_smoke" \
            | /usr/bin/tr '[:lower:]' '[:upper:]' \
            | /usr/bin/tr -cd 'A-Z0-9'
    )"
    [[ "$normalized_tesseract" == *"TRANSLATISRUNTIME48291"* ]] \
        || fail "fixed Tesseract OCR smoke returned unexpected text"

    smoke_tex="$document_smoke_root/runtime.tex"
    print -r -- '\documentclass{article}\begin{document}TRANSLATIS PDF PIPELINE 48291\end{document}' \
        > "$smoke_tex"
    /usr/bin/env -i \
        HOME="$temporary_root/home" \
        TMPDIR="$temporary_root/tmp/" \
        PATH=/usr/bin:/bin \
        LANG=C LC_ALL=C \
        TECTONIC_CACHE_DIR="$runtime_root/share/tectonic/cache" \
        /usr/bin/arch -"$expected_architecture" \
        "$runtime_root/bin/tectonic" \
        --untrusted --only-cached \
        --outdir "$document_smoke_root/tectonic-output" \
        "$smoke_tex" >/dev/null 2>&1 \
        || fail "fixed Tectonic offline compilation smoke failed"
    smoke_pdf="$document_smoke_root/tectonic-output/runtime.pdf"
    [[ -s "$smoke_pdf" ]] || fail "fixed Tectonic smoke produced no PDF"

    docling_pdf_smoke="$(
        run_python_for_architecture "$runtime_root/bin/python3" -I -B -c '
from pathlib import Path
from docling.datamodel.base_models import ConversionStatus, InputFormat
from docling.datamodel.pipeline_options import PdfPipelineOptions, TesseractCliOcrOptions
from docling.document_converter import DocumentConverter, PdfFormatOption
import sys
runtime, source = Path(sys.argv[1]), sys.argv[2]
options = PdfPipelineOptions()
options.enable_remote_services = False
options.allow_external_plugins = False
options.artifacts_path = runtime / "models" / "docling"
options.do_ocr = True
options.do_table_structure = False
options.do_code_enrichment = False
options.do_formula_enrichment = False
options.do_picture_classification = False
options.do_picture_description = False
options.do_chart_extraction = False
options.generate_page_images = False
options.generate_picture_images = False
options.generate_table_images = False
options.generate_parsed_pages = False
options.ocr_options = TesseractCliOcrOptions(
    lang=["eng"],
    tesseract_cmd=str(runtime / "bin" / "tesseract"),
    path=str(runtime / "share" / "tessdata"),
    psm=3,
    force_full_page_ocr=True,
)
converter = DocumentConverter(
    allowed_formats=[InputFormat.PDF],
    format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=options)},
)
conversion = converter.convert(
    source,
    raises_on_error=True,
    max_num_pages=1,
    max_file_size=10 * 1024 * 1024,
)
assert conversion.status == ConversionStatus.SUCCESS and not conversion.errors
assert conversion.document.export_to_markdown().strip()
print("pdf-ok")
' "$runtime_root" "$smoke_pdf"
    )" || fail "fixed Docling PDF/OCR/model pipeline smoke failed"
    [[ "${docling_pdf_smoke##*$'\n'}" == "pdf-ok" ]] \
        || fail "fixed Docling PDF/OCR/model pipeline returned unexpected output"
fi

print -- "Validated document runtime $expected_architecture ($validation_mode) at $runtime_root"
