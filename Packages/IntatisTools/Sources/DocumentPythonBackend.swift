import Foundation
import IntatisCore
import IntatisProtocol

struct DocumentBackendEnvelope: Decodable, Sendable {
    let schemaVersion: Int
    let ok: Bool
    let code: String?
    let summary: String?
    let engineVersions: [String: String]
    let result: JSONValue?
    let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ok, code, summary
        case engineVersions = "engine_versions"
        case result, warnings
    }
}

/// Pinned Python document boundary. Ordinary DOCX/PPTX/XLSX/HTML/EPUB reads
/// delegate conversion to Docling and only return bounded Markdown. The longer
/// allowlisted adapters below remain for explicit write verification and OCR;
/// they are not part of the ordinary read path.
enum DocumentPythonBackend {
    static let schemaVersion = 1
    static let pinnedVersions: [String: String] = [
        "python": "3.11.9",
        "python-docx": "1.2.0",
        "python-pptx": "1.0.2",
        "openpyxl": "3.1.5",
        "lxml": "6.1.1",
        "docling": "2.117.0",
        "docling-core": "2.89.0",
        "docling-parse": "7.8.1",
        "pypdfium2": "5.12.1",
    ]

    static func invocation(
        operation: String,
        payload: JSONValue,
        readableWorkspacePaths: [String],
        writableWorkspacePaths: [String] = [],
        internalWritableWorkspacePaths: [String] = [],
        internalReadOnlyWorkspacePaths: [String] = []
    ) throws -> DocumentBackendInvocation {
        let request: JSONValue = .object([
            "schema_version": .number(Double(schemaVersion)),
            "operation": .string(operation),
            "payload": payload,
        ])
        let data = try JSONEncoder.sortedDocumentEncoder.encode(request)
        guard let encoded = String(data: data, encoding: .utf8),
              encoded.utf8.count <= 256 * 1_024 else {
            throw DocumentToolError(
                .validationFailed,
                "document backend request exceeds the fixed envelope limit")
        }
        return DocumentBackendInvocation(
            executable: .pythonRuntime,
            arguments: ["-I", "-B", "-c", program],
            environment: [
                IntatisHostApplication.identity.environmentVariable(
                    "DOCUMENT_REQUEST"): encoded,
                IntatisHostApplication.identity.environmentVariable(
                    "DOCUMENT_OPERATION"): operation,
                "PYTHONHASHSEED": "0",
            ],
            readableWorkspacePaths: readableWorkspacePaths,
            writableWorkspacePaths: writableWorkspacePaths,
            internalWritableWorkspacePaths: internalWritableWorkspacePaths,
            internalReadOnlyWorkspacePaths: internalReadOnlyWorkspacePaths)
    }

    static func run(
        operation: String,
        payload: JSONValue,
        readableWorkspacePaths: [String],
        writableWorkspacePaths: [String] = [],
        internalWritableWorkspacePaths: [String] = [],
        internalReadOnlyWorkspacePaths: [String] = [],
        in context: ToolContext
    ) async throws -> DocumentBackendEnvelope {
        let invocation = try invocation(
            operation: operation,
            payload: payload,
            readableWorkspacePaths: readableWorkspacePaths,
            writableWorkspacePaths: writableWorkspacePaths,
            internalWritableWorkspacePaths: internalWritableWorkspacePaths,
            internalReadOnlyWorkspacePaths: internalReadOnlyWorkspacePaths)
        let result: ShellResult
        do {
            result = try await context.documentBackend.run(
                invocation,
                cwd: context.workspaceRoot)
        } catch let error as DocumentToolError {
            throw error
        } catch let error as IntatisError {
            if case .config = error {
                throw DocumentToolError(.backendMissing, "fixed Python document runtime is unavailable")
            }
            throw DocumentToolError(.backendFailed, "document backend could not be started")
        } catch {
            throw DocumentToolError(.backendFailed, "document backend could not be started")
        }
        guard result.exitCode == 0 else {
            throw DocumentToolError(.backendFailed, "fixed document backend exited unsuccessfully")
        }
        guard result.stdout.utf8.count <= 8 * 1_024 * 1_024,
              let data = result.stdout.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(
                  DocumentBackendEnvelope.self,
                  from: data),
              envelope.schemaVersion == schemaVersion else {
            throw DocumentToolError(.backendFailed, "document backend returned an invalid envelope")
        }
        guard envelope.ok else {
            let code = envelope.code.flatMap(DocumentToolErrorCode.init(rawValue:))
                ?? .backendFailed
            throw DocumentToolError(code, sanitizedSummary(for: code, envelope.summary))
        }
        return envelope
    }

    static func fixedOCRPayload(
        inputPath: String,
        maximumCharacters: Int,
        maximumFileBytes: Int
    ) throws -> JSONValue {
        guard let runtime = intatisDocumentRuntimeRoot() else {
            throw DocumentToolError(.backendMissing, "fixed document runtime root is unavailable")
        }
        let artifacts = runtime.appendingPathComponent("models/docling", isDirectory: true)
        #if os(macOS)
        let bundledRuntime = intatisBundledDocumentRuntimeRoot()
        let tesseract = bundledRuntime == nil
            ? URL(fileURLWithPath: "/opt/homebrew/bin/tesseract")
            : runtime.appendingPathComponent("bin/tesseract")
        let tessdata = bundledRuntime == nil
            ? URL(fileURLWithPath: "/opt/homebrew/share/tessdata", isDirectory: true)
            : runtime.appendingPathComponent("share/tessdata", isDirectory: true)
        #else
        let tesseract = runtime.appendingPathComponent("bin/tesseract")
        let tessdata = runtime.appendingPathComponent("share/tessdata", isDirectory: true)
        #endif
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: artifacts.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: tesseract.path),
              FileManager.default.fileExists(atPath: tessdata.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DocumentToolError(
                .backendMissing,
                "fixed Docling models, Tesseract, or tessdata are unavailable")
        }
        guard FileManager.default.fileExists(
            atPath: tessdata.appendingPathComponent("eng.traineddata").path) else {
            throw DocumentToolError(
                .backendMissing,
                "the fixed English tessdata file is unavailable")
        }
        return .object([
            "input_path": .string(inputPath),
            "maximum_characters": .number(Double(maximumCharacters)),
            "maximum_file_bytes": .number(Double(maximumFileBytes)),
            "artifacts_path": .string(artifacts.path),
            "tesseract_path": .string(tesseract.path),
            "tessdata_path": .string(tessdata.path),
        ])
    }

    private static func sanitizedSummary(
        for code: DocumentToolErrorCode,
        _ backendSummary: String?
    ) -> String {
        switch code {
        case .backendMissing:
            return "a fixed document backend component is unavailable"
        case .backendVersionMismatch:
            return "a fixed document backend has an unexpected version"
        case .unsupportedOperation:
            return "the requested format/operation is not supported"
        case .unsupportedFeature:
            return "the document uses a feature outside the supported subset"
        case .ocrRequired:
            return "the document requires explicit OCR"
        case .validationFailed:
            return "the document or requested projection failed validation"
        case .renderFailed:
            return "the document could not be rendered"
        case .outputConflict:
            return "the reviewed source or destination changed"
        case .commitUncertain:
            return "the document commit could not be reconciled"
        case .backendFailed:
            // Unexpected backend exceptions can contain absolute paths, cell
            // contents, relationship targets, or library-specific reprs. The
            // typed code is sufficient for callers; never surface that text.
            return "the fixed document backend failed"
        }
    }

    // The program deliberately contains no backend search or fallback loop.
    // Every branch imports exactly one semantic library for one format.
    private static var program: String {
        programTemplate
            .replacingOccurrences(
                of: "INTATIS_DOCUMENT_REQUEST",
                with: IntatisHostApplication.identity.environmentVariable(
                    "DOCUMENT_REQUEST"))
            .replacingOccurrences(
                of: "INTATIS_DOCUMENT_OPERATION",
                with: IntatisHostApplication.identity.environmentVariable(
                    "DOCUMENT_OPERATION"))
    }

    private static let programTemplate = #"""
import json
import math
import os
import pathlib
import re
import stat
import sys
import unicodedata
import zipfile
from importlib import metadata

SCHEMA_VERSION = 1
MAXIMUM_PDF_PAGES = 100000
MAXIMUM_OOXML_ENTRIES = 20000
MAXIMUM_OOXML_ENTRY_BYTES = 256 * 1024 * 1024
MAXIMUM_OOXML_TOTAL_BYTES = 1024 * 1024 * 1024
MAXIMUM_OOXML_COMPRESSION_RATIO = 200
EXPECTED = {
    'python': '3.11.9',
    'python-docx': '1.2.0',
    'python-pptx': '1.0.2',
    'openpyxl': '3.1.5',
    'lxml': '6.1.1',
    'docling': '2.117.0',
    'docling-core': '2.89.0',
    'docling-parse': '7.8.1',
    'pypdfium2': '5.12.1',
}

class ToolFailure(Exception):
    def __init__(self, code, summary):
        super().__init__(summary)
        self.code = code
        self.summary = summary

def emit(ok, result=None, versions=None, warnings=None, code=None, summary=None):
    value = {
        'schema_version': SCHEMA_VERSION,
        'ok': bool(ok),
        'engine_versions': versions or {},
        'warnings': warnings or [],
    }
    if result is not None:
        value['result'] = result
    if code is not None:
        value['code'] = code
    if summary is not None:
        value['summary'] = str(summary)[:240]
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')))

def require_request():
    raw = os.environ.get('INTATIS_DOCUMENT_REQUEST')
    if not raw or len(raw.encode('utf-8')) > 262144:
        raise ToolFailure('validation_failed', 'invalid request envelope')
    value = json.loads(raw)
    if set(value) != {'schema_version', 'operation', 'payload'}:
        raise ToolFailure('validation_failed', 'invalid request fields')
    if value['schema_version'] != SCHEMA_VERSION:
        raise ToolFailure('backend_version_mismatch', 'request schema mismatch')
    if value['operation'] not in ROUTES:
        raise ToolFailure('unsupported_operation', 'unsupported fixed Python route')
    if os.environ.get('INTATIS_DOCUMENT_OPERATION') != value['operation']:
        raise ToolFailure('validation_failed', 'operation binding mismatch')
    if not isinstance(value['payload'], dict):
        raise ToolFailure('validation_failed', 'payload must be an object')
    return value['operation'], value['payload']

def require_versions(distributions):
    versions = {'python': '.'.join(str(v) for v in sys.version_info[:3])}
    if versions['python'] != EXPECTED['python']:
        raise ToolFailure('backend_version_mismatch', 'python version mismatch')
    for distribution in distributions:
        try:
            actual = metadata.version(distribution)
        except metadata.PackageNotFoundError:
            raise ToolFailure('backend_missing', distribution + ' is not installed')
        versions[distribution] = actual
        if actual != EXPECTED[distribution]:
            raise ToolFailure('backend_version_mismatch', distribution + ' version mismatch')
    return versions

def safe_input(payload, suffix):
    path = payload.get('input_path')
    if not isinstance(path, str) or not os.path.isabs(path) or '\x00' in path or len(path) > 4096:
        raise ToolFailure('validation_failed', 'input_path must be an absolute host path')
    candidate = pathlib.Path(path)
    allowed_suffixes = {suffix} if isinstance(suffix, str) else set(suffix)
    if candidate.suffix.lower() not in allowed_suffixes or not candidate.is_file() or candidate.is_symlink():
        raise ToolFailure('validation_failed', 'input file is missing or has the wrong format')
    return candidate

def safe_zip_member_name(raw_name):
    if (not isinstance(raw_name, str) or not raw_name or '\x00' in raw_name
            or len(raw_name.encode('utf-8')) > 1024 or '\\' in raw_name
            or raw_name.startswith('/') or re.match(r'^[A-Za-z]:', raw_name)):
        raise ToolFailure('validation_failed', 'OOXML package contains an unsafe member name')
    parts = pathlib.PurePosixPath(raw_name).parts
    if not parts or any(part in {'', '.', '..'} for part in parts):
        raise ToolFailure('validation_failed', 'OOXML package contains an unsafe member path')
    normalized = unicodedata.normalize('NFC', raw_name.rstrip('/')).casefold()
    if not normalized:
        raise ToolFailure('validation_failed', 'OOXML package contains an unsafe member name')
    return normalized

def preflight_ooxml_container(path):
    try:
        with zipfile.ZipFile(str(path), mode='r', allowZip64=True) as archive:
            entries = archive.infolist()
            if not 1 <= len(entries) <= MAXIMUM_OOXML_ENTRIES:
                raise ToolFailure('validation_failed', 'OOXML package entry count exceeds its fixed boundary')
            seen = set()
            total_uncompressed = 0
            for entry in entries:
                normalized = safe_zip_member_name(entry.filename)
                if normalized in seen:
                    raise ToolFailure('validation_failed', 'OOXML package contains duplicate member names')
                seen.add(normalized)
                unix_mode = (entry.external_attr >> 16) & 0xFFFF
                if stat.S_ISLNK(unix_mode):
                    raise ToolFailure('validation_failed', 'OOXML package contains a symbolic-link member')
                if entry.flag_bits & 0x1:
                    raise ToolFailure('unsupported_feature', 'encrypted OOXML packages are not supported')
                if entry.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}:
                    raise ToolFailure('unsupported_feature', 'OOXML package compression is not supported')
                if (entry.file_size < 0 or entry.compress_size < 0
                        or entry.file_size > MAXIMUM_OOXML_ENTRY_BYTES):
                    raise ToolFailure('validation_failed', 'OOXML package member exceeds its fixed boundary')
                total_uncompressed += entry.file_size
                if total_uncompressed > MAXIMUM_OOXML_TOTAL_BYTES:
                    raise ToolFailure('validation_failed', 'OOXML package exceeds its aggregate expansion boundary')
                if entry.file_size > 1024 * 1024:
                    if entry.compress_size == 0 or entry.file_size / entry.compress_size > MAXIMUM_OOXML_COMPRESSION_RATIO:
                        raise ToolFailure('validation_failed', 'OOXML package compression ratio exceeds its fixed boundary')
    except ToolFailure:
        raise
    except (OSError, RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile):
        raise ToolFailure('validation_failed', 'OOXML package central directory is invalid') from None

def read_path(payload, suffix):
    allowed_keys = {
        'input_path', 'maximum_characters', 'maximum_file_bytes',
        'start_element', 'start_character_offset'
    }
    if set(payload) - allowed_keys or 'input_path' not in payload:
        raise ToolFailure('validation_failed', 'document read payload fields are invalid')
    return safe_input(payload, suffix)

def read_docling(payload, path, format_name, dependencies,
                 input_format, option_type, backend_options):
    versions = require_versions(
        ['docling', 'docling-core', 'docling-parse'] + dependencies)
    from docling.datamodel.base_models import ConversionStatus
    from docling.datamodel.pipeline_options import ConvertPipelineOptions
    from docling.document_converter import DocumentConverter
    maximum_characters = int(payload.get('maximum_characters', 200000))
    maximum_file_bytes = int(payload.get('maximum_file_bytes', 512 * 1024 * 1024))
    if not 1 <= maximum_characters <= 500000 or not 1 <= maximum_file_bytes <= 512 * 1024 * 1024:
        raise ToolFailure('validation_failed', 'document read bounds are invalid')
    pipeline_options = ConvertPipelineOptions(
        document_timeout=240.0,
        enable_remote_services=False,
        allow_external_plugins=False,
        do_picture_classification=False,
        do_picture_description=False,
        do_chart_extraction=False)
    converter = DocumentConverter(
        allowed_formats=[input_format],
        format_options={input_format: option_type(
            pipeline_options=pipeline_options,
            backend_options=backend_options)})
    conversion = converter.convert(
        str(path),
        raises_on_error=True,
        max_num_pages=100000,
        max_file_size=maximum_file_bytes)
    if conversion.status != ConversionStatus.SUCCESS or conversion.errors:
        raise ToolFailure('backend_failed', 'fixed Docling conversion did not complete')
    from docling_core.transforms.chunker import HierarchicalChunker
    from docling_core.types.doc import DocItem, GroupItem

    document = conversion.document
    items = list(document.iterate_items(
        with_groups=True,
        traverse_pictures=True))
    total_elements = len(items)
    start_element = payload.get('start_element', 1)
    start_character_offset = payload.get('start_character_offset', 0)
    if (isinstance(start_element, bool) or not isinstance(start_element, int)
            or isinstance(start_character_offset, bool)
            or not isinstance(start_character_offset, int)
            or start_element < 1 or start_element > total_elements
            or start_character_offset < 0
            or start_character_offset > 512 * 1024 * 1024):
        raise ToolFailure('validation_failed', 'document continuation position is invalid')

    def export_range(start, end):
        return document.export_to_markdown(
            from_element=start,
            to_element=end,
            image_placeholder='<!-- image omitted -->',
            traverse_pictures=False)

    def next_document_item(element):
        while element < total_elements:
            if isinstance(items[element][0], DocItem):
                return element
            element += 1
        return None

    start_element = next_document_item(start_element)
    first_markdown = ''
    while start_element is not None:
        first_markdown = export_range(start_element, start_element + 1)
        if start_character_offset > len(first_markdown):
            raise ToolFailure('validation_failed', 'document cursor no longer matches its element')
        if start_character_offset < len(first_markdown):
            break
        start_character_offset = 0
        start_element = next_document_item(start_element + 1)

    next_element = None
    next_character_offset = 0
    if start_element is None:
        markdown = ''
    else:
        first_remaining = first_markdown[start_character_offset:]
        if len(first_remaining) > maximum_characters:
            markdown = first_remaining[:maximum_characters]
            next_element = start_element
            next_character_offset = start_character_offset + maximum_characters
        else:
            low = start_element + 1
            high = total_elements
            best_end = low
            markdown = first_remaining
            while low <= high:
                middle = (low + high) // 2
                candidate = export_range(start_element, middle)[start_character_offset:]
                if len(candidate) <= maximum_characters:
                    best_end = middle
                    markdown = candidate
                    low = middle + 1
                else:
                    high = middle - 1
            next_element = next_document_item(best_end)

    reference_indexes = {
        str(item.self_ref): index
        for index, (item, _) in enumerate(items)
        if isinstance(item, DocItem)
    }
    raw_landmarks = []
    seen_landmarks = set()

    def clean_landmark_text(value):
        if not isinstance(value, str):
            return None
        cleaned = ' '.join(value.split())
        if not cleaned:
            return None
        return cleaned[:240]

    def add_landmark(kind, title, element, page=None):
        title = clean_landmark_text(title)
        if title is None or not isinstance(element, int) or element < 1:
            return
        key = (kind, title, element)
        if key in seen_landmarks:
            return
        seen_landmarks.add(key)
        landmark = {'kind': kind, 'title': title, 'element': element}
        if isinstance(page, int) and page > 0:
            landmark['page'] = page
        raw_landmarks.append(landmark)

    for index, (item, _) in enumerate(items):
        label_value = getattr(getattr(item, 'label', None), 'value', '')
        if isinstance(item, DocItem) and label_value in {'title', 'section_header'}:
            add_landmark('section', getattr(item, 'text', None), index)
        elif isinstance(item, GroupItem):
            group_name = clean_landmark_text(getattr(item, 'name', None))
            first_child = next_document_item(index + 1)
            if group_name is not None and first_child is not None:
                add_landmark(label_value or 'group', group_name, first_child)

    warnings = []
    try:
        chunks = HierarchicalChunker().chunk(document)
        for chunk in chunks:
            chunk_items = getattr(chunk.meta, 'doc_items', None) or []
            element = next((reference_indexes.get(str(item.self_ref))
                            for item in chunk_items
                            if reference_indexes.get(str(item.self_ref)) is not None), None)
            headings = getattr(chunk.meta, 'headings', None) or []
            title = ' / '.join(str(value) for value in headings[-3:])
            if element is not None:
                add_landmark('semantic_section', title, element)
    except Exception:
        warnings.append(
            'Docling semantic landmarks were unavailable; sequential continuation remains available')

    first_element_for_page = {}
    for index, (item, _) in enumerate(items):
        if not isinstance(item, DocItem):
            continue
        provenance = getattr(item, 'prov', None) or []
        page = getattr(provenance[0], 'page_no', None) if provenance else None
        if isinstance(page, int) and page > 0 and page not in first_element_for_page:
            first_element_for_page[page] = index
    page_kind = 'slide' if format_name == 'pptx' else ('sheet' if format_name == 'xlsx' else 'page')
    for page, element in sorted(first_element_for_page.items()):
        add_landmark(page_kind, '{} {}'.format(page_kind.title(), page), element, page)

    raw_landmarks.sort(key=lambda value: (value['element'], value['kind'], value['title']))
    landmarks_truncated = len(raw_landmarks) > 256
    if landmarks_truncated:
        last = len(raw_landmarks) - 1
        selected_indexes = sorted(set(round(index * last / 255) for index in range(256)))
        raw_landmarks = [raw_landmarks[index] for index in selected_indexes]

    navigation = {
        'source_element_count': total_elements,
        'next': ({'element': next_element,
                  'character_offset': next_character_offset}
                 if next_element is not None else None),
        'landmarks': raw_landmarks,
        'landmarks_truncated': landmarks_truncated,
    }
    return {'format': format_name,
            'markdown': markdown,
            'truncated': next_element is not None,
            'navigation': navigation}, versions, warnings

def read_docx(payload):
    from docling.datamodel.backend_options import MsWordBackendOptions
    from docling.datamodel.base_models import InputFormat
    from docling.document_converter import WordFormatOption
    path = read_path(payload, '.docx')
    preflight_ooxml_container(path)
    return read_docling(
        payload, path, 'docx', ['python-docx', 'lxml'],
        InputFormat.DOCX, WordFormatOption,
        MsWordBackendOptions(enable_remote_fetch=False,
                             enable_local_fetch=False,
                             render_chart_images=False))

def read_pptx(payload):
    from docling.datamodel.backend_options import MsPowerpointBackendOptions
    from docling.datamodel.base_models import InputFormat
    from docling.document_converter import PowerpointFormatOption
    path = read_path(payload, '.pptx')
    preflight_ooxml_container(path)
    return read_docling(
        payload, path, 'pptx', ['python-pptx', 'lxml'],
        InputFormat.PPTX, PowerpointFormatOption,
        MsPowerpointBackendOptions(enable_remote_fetch=False,
                                   enable_local_fetch=False,
                                   render_chart_images=False))

def read_xlsx(payload):
    from docling.datamodel.backend_options import MsExcelBackendOptions
    from docling.datamodel.base_models import InputFormat
    from docling.document_converter import ExcelFormatOption
    path = read_path(payload, '.xlsx')
    preflight_ooxml_container(path)
    return read_docling(
        payload, path, 'xlsx', ['openpyxl'],
        InputFormat.XLSX, ExcelFormatOption,
        MsExcelBackendOptions(enable_remote_fetch=False,
                              enable_local_fetch=False,
                              render_chart_images=False))

def read_html(payload):
    from docling.datamodel.backend_options import HTMLBackendOptions
    from docling.datamodel.base_models import InputFormat
    from docling.document_converter import HTMLFormatOption
    path = read_path(payload, {'.html', '.htm'})
    return read_docling(
        payload, path, 'html', ['lxml'],
        InputFormat.HTML, HTMLFormatOption,
        HTMLBackendOptions(enable_remote_fetch=False,
                           enable_local_fetch=False,
                           render_page=False,
                           fetch_images=False))

def read_epub(payload):
    from docling.datamodel.backend_options import EpubBackendOptions
    from docling.datamodel.base_models import InputFormat
    from docling.document_converter import EpubFormatOption
    path = read_path(payload, '.epub')
    return read_docling(
        payload, path, 'epub', ['lxml'],
        InputFormat.EPUB, EpubFormatOption,
        EpubBackendOptions(enable_remote_fetch=False,
                           enable_local_fetch=False,
                           fetch_images=False,
                           max_total_bytes=512 * 1024 * 1024,
                           max_file_bytes=256 * 1024 * 1024,
                           max_member_count=20000))

def require_exact_keys(value, allowed, required, label):
    if not isinstance(value, dict) or not set(value) <= set(allowed) or not set(required) <= set(value):
        raise ToolFailure('validation_failed', label + ' fields are invalid')

def require_string(value, label, minimum=0, maximum=1000000):
    if not isinstance(value, str) or not minimum <= len(value) <= maximum or '\x00' in value:
        raise ToolFailure('validation_failed', label + ' is invalid')
    return value

def require_integer(value, label, minimum=0, maximum=1000000):
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise ToolFailure('validation_failed', label + ' is invalid')
    return value

def require_number(value, label, minimum=-1000000000000, maximum=1000000000000):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ToolFailure('validation_failed', label + ' is invalid')
    if not minimum <= value <= maximum:
        raise ToolFailure('validation_failed', label + ' is invalid')
    return value

def require_boolean(value, label):
    if not isinstance(value, bool):
        raise ToolFailure('validation_failed', label + ' is invalid')
    return value

def require_scalar(value, label):
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return require_number(value, label)
    if isinstance(value, str):
        return require_string(value, label, maximum=65536)
    raise ToolFailure('validation_failed', label + ' is invalid')

def safe_output(payload, suffixes):
    path = payload.get('output_path')
    if not isinstance(path, str) or not os.path.isabs(path) or '\x00' in path or len(path) > 4096:
        raise ToolFailure('validation_failed', 'output_path must be an absolute host path')
    candidate = pathlib.Path(path)
    allowed_suffixes = {suffixes} if isinstance(suffixes, str) else set(suffixes)
    if candidate.suffix.lower() not in allowed_suffixes:
        raise ToolFailure('validation_failed', 'output_path has the wrong format')
    if candidate.exists() or candidate.is_symlink():
        raise ToolFailure('validation_failed', 'staged output already exists')
    parent = candidate.parent
    if not parent.is_dir() or parent.is_symlink():
        raise ToolFailure('validation_failed', 'staged output parent is unsafe')
    return candidate

def safe_asset(path, image_only=False):
    require_string(path, 'asset path', minimum=1, maximum=4096)
    if not os.path.isabs(path):
        raise ToolFailure('validation_failed', 'asset path must be an absolute host path')
    candidate = pathlib.Path(path)
    if not candidate.is_file() or candidate.is_symlink():
        raise ToolFailure('validation_failed', 'asset file is missing or unsafe')
    if image_only and candidate.suffix.lower() not in {'.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tif', '.tiff'}:
        raise ToolFailure('unsupported_feature', 'image asset format is not supported')
    return candidate

def save_package_exclusive(value, output):
    flags = os.O_CREAT | os.O_EXCL | os.O_RDWR
    if hasattr(os, 'O_NOFOLLOW'):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(str(output), flags, 0o600)
    try:
        with os.fdopen(descriptor, 'w+b') as stream:
            descriptor = -1
            value.save(stream)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)

def finalize_output(output):
    status = os.lstat(str(output))
    if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1 or not 0 < status.st_size <= 1073741824:
        raise ToolFailure('validation_failed', 'staged output is not a bounded single-link regular file')
    os.chmod(str(output), 0o600, follow_symlinks=False)

def exact_create(payload, suffix, fields):
    require_exact_keys(payload, set(fields) | {'output_path'}, {'output_path'}, 'create payload')
    return safe_output(payload, suffix)

def exact_mutation(payload, suffix, fields, required):
    allowed = set(fields) | {'input_path', 'output_path'}
    required_fields = set(required) | {'input_path', 'output_path'}
    require_exact_keys(payload, allowed, required_fields, 'mutation payload')
    return safe_input(payload, suffix), safe_output(payload, suffix)

def indexed(values, index, label, maximum=1000000):
    index = require_integer(index, label + '_index', 0, maximum)
    if index >= len(values):
        raise ToolFailure('validation_failed', label + '_index is outside the document')
    return values[index]

def save_document(value, output, format_name, external_operation, versions):
    try:
        save_package_exclusive(value, output)
        finalize_output(output)
    except ToolFailure:
        raise
    except (OSError, ValueError, TypeError, KeyError, IndexError):
        raise ToolFailure('backend_failed', 'external document operation failed') from None
    return {
        'format': format_name,
        'external_operation': external_operation,
    }, versions, []

def load_docx(payload, fields, required):
    input_path, output = exact_mutation(payload, '.docx', fields, required)
    preflight_ooxml_container(input_path)
    versions = require_versions(['python-docx'])
    from docx import Document
    try:
        return Document(str(input_path)), output, versions
    except Exception:
        raise ToolFailure('validation_failed', 'DOCX input could not be opened') from None

def docx_create_document(payload):
    output = exact_create(payload, '.docx', set())
    versions = require_versions(['python-docx'])
    from docx import Document
    return save_document(Document(), output, 'docx', 'Document()', versions)

def docx_add_paragraph(payload):
    fields = {'text', 'style'}
    document, output, versions = load_docx(payload, fields, set())
    text = require_string(payload.get('text', ''), 'text', maximum=1000000)
    style = require_string(payload['style'], 'style', 1, 255) if 'style' in payload else None
    document.add_paragraph(text=text, style=style)
    return save_document(document, output, 'docx', 'Document.add_paragraph', versions)

def docx_set_paragraph_text(payload):
    fields = {'paragraph_index', 'text'}
    document, output, versions = load_docx(payload, fields, fields)
    paragraph = indexed(document.paragraphs, payload['paragraph_index'], 'paragraph')
    paragraph.text = require_string(payload['text'], 'text', maximum=1000000)
    return save_document(document, output, 'docx', 'Paragraph.text', versions)

def docx_add_run(payload):
    fields = {'paragraph_index', 'text', 'style'}
    document, output, versions = load_docx(payload, fields, {'paragraph_index'})
    paragraph = indexed(document.paragraphs, payload['paragraph_index'], 'paragraph')
    text = require_string(payload.get('text', ''), 'text', maximum=1000000)
    style = require_string(payload['style'], 'style', 1, 255) if 'style' in payload else None
    paragraph.add_run(text=text, style=style)
    return save_document(document, output, 'docx', 'Paragraph.add_run', versions)

def docx_run_property(payload, property_name):
    fields = {'paragraph_index', 'run_index', 'value'}
    document, output, versions = load_docx(payload, fields, fields)
    paragraph = indexed(document.paragraphs, payload['paragraph_index'], 'paragraph')
    run = indexed(paragraph.runs, payload['run_index'], 'run')
    setattr(run, property_name, require_boolean(payload['value'], 'value'))
    return save_document(document, output, 'docx', 'Run.' + property_name, versions)

def docx_set_run_bold(payload):
    return docx_run_property(payload, 'bold')

def docx_set_run_italic(payload):
    return docx_run_property(payload, 'italic')

def docx_set_run_underline(payload):
    return docx_run_property(payload, 'underline')

def docx_add_table(payload):
    fields = {'rows', 'cols', 'style'}
    document, output, versions = load_docx(payload, fields, {'rows', 'cols'})
    rows = require_integer(payload['rows'], 'rows', 1, 100000)
    cols = require_integer(payload['cols'], 'cols', 1, 16384)
    style = require_string(payload['style'], 'style', 1, 255) if 'style' in payload else None
    document.add_table(rows=rows, cols=cols, style=style)
    return save_document(document, output, 'docx', 'Document.add_table', versions)

def docx_set_table_cell_text(payload):
    fields = {'table_index', 'row_index', 'column_index', 'text'}
    document, output, versions = load_docx(payload, fields, fields)
    table = indexed(document.tables, payload['table_index'], 'table', 100000)
    row = indexed(table.rows, payload['row_index'], 'row')
    cell = indexed(row.cells, payload['column_index'], 'column', 16383)
    cell.text = require_string(payload['text'], 'text', maximum=1000000)
    return save_document(document, output, 'docx', '_Cell.text', versions)

def docx_add_picture(payload):
    fields = {'path', 'width', 'height'}
    document, output, versions = load_docx(payload, fields, {'path'})
    asset = safe_asset(payload['path'], image_only=True)
    kwargs = {}
    if 'width' in payload:
        kwargs['width'] = require_integer(payload['width'], 'width', 0, 2147483647)
    if 'height' in payload:
        kwargs['height'] = require_integer(payload['height'], 'height', 0, 2147483647)
    document.add_picture(str(asset), **kwargs)
    return save_document(document, output, 'docx', 'Document.add_picture', versions)

def docx_header_footer_text(payload, region):
    fields = {'section_index', 'paragraph_index', 'text'}
    document, output, versions = load_docx(payload, fields, fields)
    section = indexed(document.sections, payload['section_index'], 'section')
    container = section.header if region == 'header' else section.footer
    paragraph = indexed(container.paragraphs, payload['paragraph_index'], 'paragraph')
    paragraph.text = require_string(payload['text'], 'text', maximum=1000000)
    return save_document(document, output, 'docx', region.title() + ' Paragraph.text', versions)

def docx_set_header_paragraph_text(payload):
    return docx_header_footer_text(payload, 'header')

def docx_set_footer_paragraph_text(payload):
    return docx_header_footer_text(payload, 'footer')

def docx_set_section_orientation(payload):
    fields = {'section_index', 'orientation'}
    document, output, versions = load_docx(payload, fields, fields)
    from docx.enum.section import WD_ORIENT
    section = indexed(document.sections, payload['section_index'], 'section')
    orientation = require_string(payload['orientation'], 'orientation', 1, 20)
    values = {'portrait': WD_ORIENT.PORTRAIT, 'landscape': WD_ORIENT.LANDSCAPE}
    if orientation not in values:
        raise ToolFailure('validation_failed', 'orientation is invalid')
    section.orientation = values[orientation]
    return save_document(document, output, 'docx', 'Section.orientation', versions)

def docx_section_margin(payload, property_name):
    fields = {'section_index', 'value'}
    document, output, versions = load_docx(payload, fields, fields)
    section = indexed(document.sections, payload['section_index'], 'section')
    setattr(section, property_name,
            require_integer(payload['value'], 'value', 0, 2147483647))
    return save_document(document, output, 'docx', 'Section.' + property_name, versions)

def docx_set_section_top_margin(payload):
    return docx_section_margin(payload, 'top_margin')

def docx_set_section_right_margin(payload):
    return docx_section_margin(payload, 'right_margin')

def docx_set_section_bottom_margin(payload):
    return docx_section_margin(payload, 'bottom_margin')

def docx_set_section_left_margin(payload):
    return docx_section_margin(payload, 'left_margin')

def load_pptx(payload, fields, required):
    input_path, output = exact_mutation(payload, '.pptx', fields, required)
    preflight_ooxml_container(input_path)
    versions = require_versions(['python-pptx'])
    from pptx import Presentation
    try:
        return Presentation(str(input_path)), output, versions
    except Exception:
        raise ToolFailure('validation_failed', 'PPTX input could not be opened') from None

def pptx_create_presentation(payload):
    output = exact_create(payload, '.pptx', set())
    versions = require_versions(['python-pptx'])
    from pptx import Presentation
    return save_document(Presentation(), output, 'pptx', 'Presentation()', versions)

def pptx_add_slide(payload):
    fields = {'slide_layout_index'}
    presentation, output, versions = load_pptx(payload, fields, fields)
    layout = indexed(presentation.slide_layouts, payload['slide_layout_index'], 'slide_layout')
    presentation.slides.add_slide(layout)
    return save_document(presentation, output, 'pptx', 'Slides.add_slide', versions)

def pptx_set_shape_text(payload):
    fields = {'slide_index', 'shape_index', 'text'}
    presentation, output, versions = load_pptx(payload, fields, fields)
    slide = indexed(presentation.slides, payload['slide_index'], 'slide')
    shape = indexed(slide.shapes, payload['shape_index'], 'shape')
    if not hasattr(shape, 'text'):
        raise ToolFailure('unsupported_feature', 'shape has no text property')
    shape.text = require_string(payload['text'], 'text', maximum=1000000)
    return save_document(presentation, output, 'pptx', 'Shape.text', versions)

def pptx_add_shape(payload):
    fields = {'slide_index', 'shape_type', 'left', 'top', 'width', 'height'}
    presentation, output, versions = load_pptx(payload, fields, fields)
    from pptx.enum.shapes import MSO_SHAPE
    slide = indexed(presentation.slides, payload['slide_index'], 'slide')
    shape_type = MSO_SHAPE(require_integer(payload['shape_type'], 'shape_type', 1, 1000))
    geometry = [require_integer(payload[name], name, 0, 2147483647)
                for name in ('left', 'top', 'width', 'height')]
    slide.shapes.add_shape(shape_type, *geometry)
    return save_document(presentation, output, 'pptx', 'SlideShapes.add_shape', versions)

def pptx_add_picture(payload):
    fields = {'slide_index', 'path', 'left', 'top', 'width', 'height'}
    required = {'slide_index', 'path', 'left', 'top'}
    presentation, output, versions = load_pptx(payload, fields, required)
    slide = indexed(presentation.slides, payload['slide_index'], 'slide')
    asset = safe_asset(payload['path'], image_only=True)
    left = require_integer(payload['left'], 'left', 0, 2147483647)
    top = require_integer(payload['top'], 'top', 0, 2147483647)
    width = require_integer(payload['width'], 'width', 0, 2147483647) if 'width' in payload else None
    height = require_integer(payload['height'], 'height', 0, 2147483647) if 'height' in payload else None
    slide.shapes.add_picture(str(asset), left, top, width, height)
    return save_document(presentation, output, 'pptx', 'SlideShapes.add_picture', versions)

def pptx_add_table(payload):
    fields = {'slide_index', 'rows', 'cols', 'left', 'top', 'width', 'height'}
    presentation, output, versions = load_pptx(payload, fields, fields)
    slide = indexed(presentation.slides, payload['slide_index'], 'slide')
    rows = require_integer(payload['rows'], 'rows', 1, 100000)
    cols = require_integer(payload['cols'], 'cols', 1, 16384)
    geometry = [require_integer(payload[name], name, 0, 2147483647)
                for name in ('left', 'top', 'width', 'height')]
    slide.shapes.add_table(rows, cols, *geometry)
    return save_document(presentation, output, 'pptx', 'SlideShapes.add_table', versions)

def pptx_set_table_cell_text(payload):
    fields = {'slide_index', 'shape_index', 'row_index', 'column_index', 'text'}
    presentation, output, versions = load_pptx(payload, fields, fields)
    slide = indexed(presentation.slides, payload['slide_index'], 'slide')
    shape = indexed(slide.shapes, payload['shape_index'], 'shape')
    if not getattr(shape, 'has_table', False):
        raise ToolFailure('unsupported_feature', 'shape is not a table')
    row = indexed(shape.table.rows, payload['row_index'], 'row')
    cell = indexed(row.cells, payload['column_index'], 'column', 16383)
    cell.text = require_string(payload['text'], 'text', maximum=1000000)
    return save_document(presentation, output, 'pptx', 'TableCell.text', versions)

def spreadsheet_scalar(value, label):
    value = require_scalar(value, label)
    if isinstance(value, str):
        if value.startswith('='):
            raise ToolFailure('unsupported_feature', 'formula creation is not supported')
    return value

def a1_cell(value):
    value = require_string(value, 'cell', 2, 16)
    if re.fullmatch(r'\$?[A-Za-z]{1,3}\$?[1-9][0-9]{0,6}', value) is None:
        raise ToolFailure('validation_failed', 'cell is invalid')
    return value

def load_xlsx(payload, fields, required):
    input_path, output = exact_mutation(payload, '.xlsx', fields, required)
    preflight_ooxml_container(input_path)
    versions = require_versions(['openpyxl'])
    from openpyxl import load_workbook
    try:
        workbook = load_workbook(str(input_path))
    except Exception:
        raise ToolFailure('validation_failed', 'XLSX input could not be opened') from None
    return workbook, output, versions

def xlsx_create_workbook(payload):
    output = exact_create(payload, '.xlsx', set())
    versions = require_versions(['openpyxl'])
    from openpyxl import Workbook
    return save_document(Workbook(), output, 'xlsx', 'Workbook()', versions)

def xlsx_create_sheet(payload):
    fields = {'title', 'index'}
    workbook, output, versions = load_xlsx(payload, fields, set())
    kwargs = {}
    if 'title' in payload:
        kwargs['title'] = require_string(payload['title'], 'title', 1, 31)
    if 'index' in payload:
        kwargs['index'] = require_integer(payload['index'], 'index', 0, 1000000)
    workbook.create_sheet(**kwargs)
    return save_document(workbook, output, 'xlsx', 'Workbook.create_sheet', versions)

def xlsx_set_sheet_title(payload):
    fields = {'sheet_index', 'title'}
    workbook, output, versions = load_xlsx(payload, fields, fields)
    sheet = indexed(workbook.worksheets, payload['sheet_index'], 'sheet')
    sheet.title = require_string(payload['title'], 'title', 1, 31)
    return save_document(workbook, output, 'xlsx', 'Worksheet.title', versions)

def xlsx_set_cell_value(payload):
    fields = {'sheet', 'cell', 'value'}
    workbook, output, versions = load_xlsx(payload, fields, fields)
    sheet_name = require_string(payload['sheet'], 'sheet', 1, 31)
    if sheet_name not in workbook.sheetnames:
        raise ToolFailure('validation_failed', 'sheet does not exist')
    workbook[sheet_name][a1_cell(payload['cell'])].value = spreadsheet_scalar(payload['value'], 'value')
    return save_document(workbook, output, 'xlsx', 'Cell.value', versions)

def xlsx_append_row(payload):
    fields = {'sheet', 'values'}
    workbook, output, versions = load_xlsx(payload, fields, fields)
    sheet_name = require_string(payload['sheet'], 'sheet', 1, 31)
    if sheet_name not in workbook.sheetnames:
        raise ToolFailure('validation_failed', 'sheet does not exist')
    values = payload['values']
    if not isinstance(values, list) or not 1 <= len(values) <= 16384:
        raise ToolFailure('validation_failed', 'values is invalid')
    workbook[sheet_name].append([spreadsheet_scalar(value, 'values') for value in values])
    return save_document(workbook, output, 'xlsx', 'Worksheet.append', versions)

def ocr_pdf(payload):
    require_exact_keys(
        payload,
        {'input_path', 'maximum_characters', 'maximum_file_bytes',
         'artifacts_path', 'tesseract_path', 'tessdata_path'},
        {'input_path', 'maximum_characters', 'maximum_file_bytes',
         'artifacts_path', 'tesseract_path', 'tessdata_path'},
        'ocr_pdf payload')
    versions = require_versions(['docling', 'docling-core', 'docling-parse', 'pypdfium2'])
    import subprocess
    from docling.datamodel.base_models import ConversionStatus, InputFormat
    from docling.datamodel.pipeline_options import PdfPipelineOptions, TesseractCliOcrOptions
    from docling.document_converter import DocumentConverter, PdfFormatOption

    path = safe_input(payload, '.pdf')
    artifacts = pathlib.Path(payload['artifacts_path'])
    tesseract = pathlib.Path(payload['tesseract_path'])
    tessdata = pathlib.Path(payload['tessdata_path'])
    if (not artifacts.is_dir() or not tesseract.is_file()
            or not os.access(tesseract, os.X_OK) or not tessdata.is_dir()
            or not (tessdata / 'eng.traineddata').is_file()):
        raise ToolFailure('backend_missing', 'fixed OCR runtime artifacts are missing')
    try:
        version_line = subprocess.run(
            [str(tesseract), '--version'], stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            check=False, text=True, timeout=5).stdout.splitlines()[0]
    except (OSError, subprocess.SubprocessError, IndexError):
        raise ToolFailure('backend_missing', 'fixed Tesseract runtime is unavailable') from None
    if version_line.strip() != 'tesseract 5.5.3':
        raise ToolFailure('backend_version_mismatch', 'tesseract version mismatch')
    versions['tesseract'] = '5.5.3'

    maximum_characters = require_integer(
        payload['maximum_characters'], 'maximum_characters', 1, 500000)
    maximum_file_bytes = require_integer(
        payload['maximum_file_bytes'], 'maximum_file_bytes', 1, 104857600)
    options = PdfPipelineOptions()
    options.enable_remote_services = False
    options.allow_external_plugins = False
    options.artifacts_path = artifacts
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
        lang=['eng'],
        tesseract_cmd=str(tesseract),
        path=str(tessdata),
        psm=3,
        force_full_page_ocr=True)
    converter = DocumentConverter(
        allowed_formats=[InputFormat.PDF],
        format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=options)})
    conversion = converter.convert(
        str(path),
        raises_on_error=True,
        max_num_pages=MAXIMUM_PDF_PAGES,
        max_file_size=maximum_file_bytes)
    if conversion.status != ConversionStatus.SUCCESS or conversion.errors:
        raise ToolFailure('backend_failed', 'fixed Docling OCR conversion did not complete')
    markdown = conversion.document.export_to_markdown(
        image_placeholder='<!-- image omitted -->',
        traverse_pictures=False)
    truncated = len(markdown) > maximum_characters
    if truncated:
        markdown = markdown[:maximum_characters]
    return {
        'format': 'pdf',
        'markdown': markdown,
        'truncated': truncated,
        'searchable_pdf_generated': False,
    }, versions, []

ROUTES = {
    'read_docx': read_docx,
    'read_pptx': read_pptx,
    'read_xlsx': read_xlsx,
    'read_html': read_html,
    'read_epub': read_epub,
    'ocr_pdf': ocr_pdf,
    'docx_create_document': docx_create_document,
    'docx_add_paragraph': docx_add_paragraph,
    'docx_set_paragraph_text': docx_set_paragraph_text,
    'docx_add_run': docx_add_run,
    'docx_set_run_bold': docx_set_run_bold,
    'docx_set_run_italic': docx_set_run_italic,
    'docx_set_run_underline': docx_set_run_underline,
    'docx_add_table': docx_add_table,
    'docx_set_table_cell_text': docx_set_table_cell_text,
    'docx_add_picture': docx_add_picture,
    'docx_set_header_paragraph_text': docx_set_header_paragraph_text,
    'docx_set_footer_paragraph_text': docx_set_footer_paragraph_text,
    'docx_set_section_orientation': docx_set_section_orientation,
    'docx_set_section_top_margin': docx_set_section_top_margin,
    'docx_set_section_right_margin': docx_set_section_right_margin,
    'docx_set_section_bottom_margin': docx_set_section_bottom_margin,
    'docx_set_section_left_margin': docx_set_section_left_margin,
    'pptx_create_presentation': pptx_create_presentation,
    'pptx_add_slide': pptx_add_slide,
    'pptx_set_shape_text': pptx_set_shape_text,
    'pptx_add_shape': pptx_add_shape,
    'pptx_add_picture': pptx_add_picture,
    'pptx_add_table': pptx_add_table,
    'pptx_set_table_cell_text': pptx_set_table_cell_text,
    'xlsx_create_workbook': xlsx_create_workbook,
    'xlsx_create_sheet': xlsx_create_sheet,
    'xlsx_set_sheet_title': xlsx_set_sheet_title,
    'xlsx_set_cell_value': xlsx_set_cell_value,
    'xlsx_append_row': xlsx_append_row,
}

def main():
    operation, payload = require_request()
    result, versions, warnings = ROUTES[operation](payload)
    emit(True, result=result, versions=versions, warnings=warnings)

try:
    main()
except ToolFailure as error:
    emit(False, code=error.code, summary=error.summary)
except ModuleNotFoundError:
    emit(False, code='backend_missing', summary='fixed Python dependency is unavailable')
except Exception:
    # Exception reprs routinely contain absolute paths, relationship targets,
    # XML snippets, cell values, and other user data. Preserve only the typed
    # failure class at this trust boundary.
    emit(False, code='backend_failed', summary='fixed document backend failed unexpectedly')
"""#
}

private extension JSONEncoder {
    static var sortedDocumentEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
