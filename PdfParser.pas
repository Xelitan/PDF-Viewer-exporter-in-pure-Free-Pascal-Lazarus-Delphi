unit PdfParser;
{$mode delphi}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
interface
uses SysUtils, Classes, Contnrs, StrUtils, Math, Graphics, PdfTypes, PdfObjects, PdfFilters,
  PdfFonts, PdfCMap, PdfGraphics, PdfCrypt, bufstream;

type
  //Raised by LoadFromFile/LoadFromStream when the document is encrypted and the
  // supplied (or empty) password does not unlock it. The GUI catches this to prompt.
  EPdfPasswordRequired = class(Exception);

  TPdfPageElementKind = (pekText, pekImage, pekInlineImage, pekPath, pekFormXObject, pekUnknown);

  //A luminosity/alpha soft mask captured from an ExtGState. The mask shape is a
  //grayscale image; AlphaAt gives the per-pixel coverage (0..1) in page space.
  TPdfSoftMask = class
  public
    MaskImage: TObject;  // TPdfImageElement holding the grayscale shape (owned)
    GrayData: TPdfBytes;  // W*H bytes (row 0 = top); filled by the renderer
    W, H: Integer;
    Matrix: TPdfMatrix;  // image unit square -> page space
    Valid: Boolean;  // a mask image was found
    Built: Boolean;  // GrayData has been rasterized
    destructor Destroy;
    override;
    function AlphaAt(PageX, PageY: Double): Double;
  end;

  TPdfPageElement = class
  public
    Kind: TPdfPageElementKind;
    Bounds: TPdfRect;
    Matrix: TPdfMatrix;
    HasClip: Boolean;  // True when Clip restricts where this element may paint
    Clip: TPdfRect;  // page-space clip rectangle (X1<X2, Y1<Y2)
    SoftMask: TObject;  // TPdfSoftMask or nil; composite this element through it
    // Non-rectangular clip paths in effect (TPdfClipPath refs, owned by page).
    // Effective clip = Clip rect ∩ intersection of these path shapes.
    ClipPaths: array of TObject;
    // Marked-content group: id of the innermost BDC/BMC block this element sits
    // inside (-1 = none). Unique per BDC instance on the page, so all elements of
    // one logical figure (e.g. a vectorized caption = one /Figure…/PlacedPDF block)
    // share the same Mark. Used to merge per-glyph vectors into one SVG.
    Mark: Integer;
  end;

  TPdfTextElement = class(TPdfPageElement)
  public
    Text: UnicodeString;
    FontName: string;
    FontSize: Double;
    BaseFont: string;  // PDF BaseFont name, e.g. "TimesNewRomanPS-ItalicMT"
    FontProgram: TPdfBytes;  // Raw TrueType bytes when the font is embedded (FontFile2)
    FillR, FillG, FillB: Double;  // Non-stroking colour (0..1), default 0,0,0 = black
    // Text rendering mode (Tr) + stroke colour/width for outlined text (e.g. the
    // cover's "5": a black stroked outline under a yellow fill).
    RenderMode: Integer;
    StrokeR, StrokeG, StrokeB: Double;
    StrokeWidth: Double;  // page-space stroke width
    AdvanceLen: Double;  // total advance length in page space (= advance * MatrixScaleX);
                             // the horizontal Bounds is degenerate for rotated text, so the
                             // renderer uses this to fit rotated runs to their true length.
    // Page-space advance width for each character in Text (same length as Text).
    // Character i occupies X range [Bounds.X1 + sum(CharWidths[0..i-1]),
    // Bounds.X1 + sum(CharWidths[0..i])].
    CharWidths: array of Double;
    constructor Create;
  end;

  TPdfImageElement = class(TPdfPageElement)
  public
    Name: string;
    Width, Height: Integer;
    ColorSpace: string;
    BitsPerComponent: Integer;  // samples per component (1,2,4,8); default 8
    Palette: TPdfBytes;  // for Indexed: expanded RGB triples (3*(hival+1) bytes)
    PaletteCount: Integer;  // number of palette entries (hival+1)
    Data: TPdfBytes;
    constructor Create(AKind: TPdfPageElementKind = pekImage);
  end;

  TPdfUnknownElement = class(TPdfPageElement)
  public
    OperatorName: string;
    constructor Create(const Op: string);
  end;

  TPdfPathPoint = record
    X, Y: Double;
  end;  // page-space coordinates
  // A subpath as an index range into a flat point buffer. Deliberately contains
  // NO managed fields: arrays of records-with-dynamic-array-fields corrupt memory
  // when grown via SetLength in this codebase, so path storage is kept flat.
  TPdfSubPath = record
    StartIdx, Count: Integer;
    Closed: Boolean;
  end;

  // A non-rectangular clip path captured at a W/W* operator, in page space.
  // Owned by the page; referenced by graphics state and elements.
  TPdfClipPath = class
  public
    Points: array of TPdfPathPoint;  // flat buffer of all subpath points
    SubPaths: array of TPdfSubPath;  // index ranges into Points
    EvenOdd: Boolean;  // True for W* (even-odd), False for W (nonzero)
  end;

  TDoubleArray = array of Double;

  // A PDF function (types 0 sampled, 2 exponential, 3 stitching). Evaluates a
  // single input t to one or more output components. Used by shadings.
  TPdfFunction = class
  public
    FunctionType: Integer;
    Domain: TDoubleArray;
    // type 2 (exponential interpolation)
    C0, C1: TDoubleArray;
    NExp: Double;
    // type 3 (stitching)
    SubFns: array of TPdfFunction;
    Bounds3, Encode3: TDoubleArray;
    // type 0 (sampled)
    Size0: array of Integer;
    BitsPerSample, NIn, NOut: Integer;
    RangeArr, Encode0, Decode0: TDoubleArray;
    Samples: TPdfBytes;
    // type 4 (PostScript calculator)
    PSProg: TObject;  // TPSNode root (parsed program), or nil
    destructor Destroy;
    override;
    function ReadSampleBits(BitOffset, NBits: Integer): Int64;
    procedure Eval(t: Double; out Outp: TDoubleArray);
    // Multi-input evaluation (needed for type-4 tint transforms). For other
    // function types it falls back to Eval using the first input.
    procedure EvalN(const Inp: TDoubleArray; out Outp: TDoubleArray);
  end;

  // A smooth-shading paint (the `sh` operator or a shading pattern). The
  // gradient is evaluated per pixel inside the element's clip rectangle.
  TPdfShadingElement = class(TPdfPageElement)
  public
    ShadingType: Integer;  // 2 = axial, 3 = radial
    Coords: TDoubleArray;  // axial: x0 y0 x1 y1 ; radial: x0 y0 r0 x1 y1 r1
    Domain: array[0..1] of Double;
    ExtendStart, ExtendEnd: Boolean;
    CTM: TPdfMatrix;  // shading space -> page space
    Func: TPdfFunction;  // owned
    // For DeviceN/Separation shadings: maps the colour function's output
    // (colorant tints) to the alternate colour space. nil for device spaces.
    TintTransform: TPdfFunction;  // owned
    destructor Destroy;
    override;
  end;

  // A vector graphics element: one or more subpaths already transformed into
  // page space, plus the fill/stroke state at paint time.
  TPdfPathElement = class(TPdfPageElement)
  public
    Points: array of TPdfPathPoint;  // flat buffer of all subpath points
    SubPaths: array of TPdfSubPath;  // index ranges into Points
    DoFill, DoStroke, EvenOdd: Boolean;
    FillR, FillG, FillB: Double;
    StrokeR, StrokeG, StrokeB: Double;
    LineWidth: Double;  // page-space line width
    constructor Create;
  end;

  TPdfPage = class
  public
    Elements: TObjectList;
    Resources: TPdfDictionaryObject;
    MediaBox: TPdfRect;
    CropBox: TPdfRect;
    Width: Double;
    Height: Double;
    LinkRects: array of TPdfRect;  // bounding boxes of /Link annotations
    LinkURLs:  array of string;  // parallel to LinkRects: external URI target ('' for non-URI links)
    RawContent: TPdfBytes;  // decoded concatenated content stream (for PdfWriter)
    SoftMasks: TObjectList;  // owns TPdfSoftMask objects referenced by elements
    ClipPaths: TObjectList;  // owns TPdfClipPath objects referenced by elements
    // Lazy content parsing: a page's content stream is interpreted only when its
    // elements are first needed (render/search/extract), so opening a document is
    // fast. OwnerDoc/PageDict are captured at page-tree walk time.
    OwnerDoc: TObject;  // TPdfDocument that owns this page
    PageDict: TPdfDictionaryObject;
    Parsed: Boolean;
    procedure EnsureParsed;
    constructor Create;
    destructor Destroy;
    override;
  end;

  TPdfXRefEntryKind = (xrekFree, xrekUncompressed, xrekCompressed);
  TPdfXRefEntry = record
    Kind: TPdfXRefEntryKind;
    Offset: Int64;
    Generation: Integer;
    ObjStreamNumber: Integer;
    ObjStreamIndex: Integer;
    Defined: Boolean;  // True once an xref section has supplied this entry
  end;

  TPdfExtraImage = record
    JpegData: TPdfBytes;
    X, Y, W, H: Double;
    ResName: AnsiString;
  end;

  TPdfExtraText = record
    Text: string;
    X, Y, FontSize: Double;
    FontName: string;
    ResName: AnsiString;
  end;

  // A user-drawn filled rectangle (DrawRect), emitted into page content on save.
  TPdfExtraRect = record
    X, Y, W, H: Double;  // page space (PDF points, origin bottom-left)
    R, G, B: Double;  // fill colour 0..1
  end;

  // A reference to a distinct embedded font program (for FontsCount/ExportFont).
  TPdfFontProgramRef = record
    Stream: TPdfStreamObject;  // the FontFile2/FontFile3 stream
    IsCFF: Boolean;  // True = CFF (needs OTF wrap); False = TrueType/OpenType
    BaseFont: string;
  end;

  TPdfDeferredStream = record
    ObjNum:  Integer;
    Stream:  TPdfStreamObject;
    Owned:   Boolean;
  end;

  TPdfFontResource = record
    FontName: string;
    FontSize: Double;
    ResName: AnsiString;
  end;

  // TPdfDocument

  TPdfDocument = class
  private
    FData: TPdfBytes;
    FXRef: array of TPdfXRefEntry;
    FXRefVisited: array of Int64;  // xref section offsets already processed (loop guard)
    FXRefOverrideFree: Boolean;  // allow a hybrid /XRefStm to replace classic free placeholders
    FBuildingMask: Boolean;  // guard against recursive soft-mask extraction
    // Vector path build buffers. These are object fields (not InterpretContent
    // locals) because nested procedures growing outer-local dynamic arrays via
    // SetLength corrupts the stack frame in FPC. InterpretContent saves/restores
    // them so nested form/mask interpretation does not clobber the caller's path.
    PathSubs: array of TPdfSubPath;  // ranges into FlatPts (no managed fields)
    FlatPts: array of TPdfPathPoint;  // flushed subpath points
    PathCur: array of TPdfPathPoint;  // in-progress subpath points
    FTrailer: TPdfDictionaryObject;
    FPages: TObjectList;
    FObjectCache: TFPHashObjectList;
    // Writer state
    FRemoved:       array of Boolean;
    FExtraImages:   array of array of TPdfExtraImage;
    FExtraTexts:    array of array of TPdfExtraText;
    FExtraRects:    array of array of TPdfExtraRect;
    FFontResources: array of TPdfFontResource;
    FFontResCount:  Integer;
    // Added-API state
    FRenderZoom:    Extended;  // render scale for RenderPageToPng
    FFontList:      array of TPdfFontProgramRef;  // distinct embedded font programs
    FFontListBuilt: Boolean;
    FMarkCounter:   Integer;  // running id for marked-content (BDC) blocks while parsing a page
    FImported:      TObjectList;  // source docs kept alive for imported pages
    // Encryption (standard security handler). FSecurity is nil for unencrypted files.
    FSecurity:      TPdfSecurityHandler;
    FEncryptReady:  Boolean;  // file key established; per-object decrypt is live
    FEncryptObjNum: Integer;  // object # of the /Encrypt dict (never decrypted)
    FDecNum, FDecGen: Integer;  // current top-level object num/gen for decryption
    FDecOn:         Boolean;  // decrypt this object's strings/streams?
    FPassword:      AnsiString;
    FOut:     TStream;
    FNextNum: Integer;
    FOffsets: array of Int64;

    function DataLength: Integer;
    function B(Pos: Integer): Byte;
    procedure SkipWs(var Pos: Integer);
    function Match(Pos: Integer; const S: AnsiString): Boolean;
    function ReadToken(var Pos: Integer): string;

    function ParseDirectObject(var Pos: Integer): TPdfObject;
    function ParseName(var Pos: Integer): TPdfNameObject;
    function ParseLiteralString(var Pos: Integer): TPdfStringObject;
    function ParseHexString(var Pos: Integer): TPdfStringObject;
    function ParseArray(var Pos: Integer): TPdfArrayObject;
    function ParseDictionary(var Pos: Integer): TPdfDictionaryObject;
    function ParseNumberOrReference(var Pos: Integer): TPdfObject;
    function ParseObjectAt(var Pos: Integer): TPdfObject;
    function DecStr(const S: AnsiString): AnsiString;  // decrypt a parsed string in the current object context

    procedure ParseXRef;
    procedure ProcessXRefSection(Off: Int64);
    procedure ParseClassicXRef(var Pos: Integer; out Trailer: TPdfDictionaryObject);
    procedure ParseXRefStreamAt(ObjNum: Integer; Stream: TPdfStreamObject);
    procedure SetXRefEntry(Index: Integer; const Entry: TPdfXRefEntry);
    procedure EnsureXRefSize(N: Integer);
    function FindStartXRef: Int64;

    function ResolveObject(Obj: TPdfObject): TPdfObject;
    function LoadIndirectObject(ObjectNumber: Integer): TPdfObject;
    function LoadCompressedObject(ObjectNumber: Integer): TPdfObject;
    function DecodeStream(Stream: TPdfStreamObject): TPdfBytes;

    procedure SetupEncryption;
    procedure BuildPages;
    procedure WalkPageTree(PageDict: TPdfDictionaryObject; ParentResources: TPdfDictionaryObject);
    procedure ParsePageContent(Page: TPdfPage; PageDict, Resources: TPdfDictionaryObject);
    procedure ParseAnnotations(Page: TPdfPage; PageDict: TPdfDictionaryObject);
    procedure InterpretContent(Page: TPdfPage; const Bytes: TPdfBytes; Resources: TPdfDictionaryObject; const InitialCTM: TPdfMatrix; InitialSoftMask: TObject = nil; InitialMark: Integer = -1);
    function BuildIndexedRGBPalette(CSArr: TPdfArrayObject; out Pal: TPdfBytes): Integer;
    function BuildFunction(Obj: TPdfObject): TPdfFunction;
    function BuildShading(ShadingObj: TPdfObject; const ACTM: TPdfMatrix): TPdfShadingElement;
    function BuildSoftMask(Page: TPdfPage; SMaskDict: TPdfDictionaryObject; const ACTM: TPdfMatrix): TPdfSoftMask;
    function BuildFontMap(Resources: TPdfDictionaryObject): TFPHashObjectList;
    // Writer helpers
    procedure WS(const A: AnsiString);
    procedure WLn(const A: AnsiString);
    procedure WF(V: Double);
    procedure WI(N: Integer);
    function  Alloc: Integer;
    procedure StartObj(N: Integer);
    procedure EndObj;
    procedure AppendObj(var Buf: AnsiString; O: TPdfObject;
                        var Deferred: array of TPdfDeferredStream;
                        var DeferCount: Integer);
    procedure BuildResources(Page: TPdfPage; PageIdx: Integer;
                             var Deferred: array of TPdfDeferredStream;
                             var DeferCount: Integer;
                             out ResBuf: AnsiString);
    function  BuildExtraOps(PageIdx: Integer): AnsiString;
    procedure WriteDeferredStream(const D: TPdfDeferredStream);
    procedure InitFromBlankPage(APageWidth, APageHeight: Double);
    procedure SyncPageArrays;
    // =- Added-API helpers =-
    procedure BuildFontList;
    procedure CollectFontsFrom(Res: TPdfObject; Seen: TList);
    function  DecodeRasterToRGB(E: TPdfImageElement; out RGB: TPdfBytes): Boolean;
  public
    constructor Create;
    overload;
    constructor Create(APageWidth, APageHeight: Double);
    overload;
    destructor Destroy;
    override;
    procedure Assign(Doc: TPdfDocument);
    procedure LoadFromFile(const FileName: string);
    overload;
    procedure LoadFromFile(const FileName: string; const Password: string);
    overload;
    procedure LoadFromStream(AStream: TStream);
    procedure SetPassword(const Password: string);  // call before Load to supply a password
    function  IsEncrypted: Boolean;
    function  IsAuthenticated: Boolean;
    function Resolve(Obj: TPdfObject): TPdfObject;
    function GetCatalog: TPdfDictionaryObject;
    // Modify and emit
    procedure RemovePage(PageIndex: Integer);
    function  AddPage(AWidth, AHeight: Double): Integer;
    procedure SaveToStream(AStream: TStream);
    procedure SaveToFile(const FileName: string);
    procedure AddJpegImage(PageIndex: Integer; const JpegData: TPdfBytes;
                           X, Y, W, H: Double);
    function  AddFont(const FontName: string; FontSize: Double): AnsiString;
    procedure AddText(PageIndex: Integer; const Text: string;
                      X, Y: Double; const FontRes: AnsiString);
    procedure ExtractTextToFile(PageIndex: Integer; const FileName: string);
    // =- Added API: asset queries / exports / edit / render =-=-=-=-=-=-=-=-=-─
    function  FontsCount: Integer;  // # of distinct embedded fonts
    procedure ExportFont(Index: Integer; const FileName: string);  // -> .OTF (CFF wrapped)
    function  VectorsCount(PageIndex: Integer): Integer;  // # of vector path elements
    procedure ExportVector(PageIndex, Index: Integer; const FileName: string);  // -> .SVG (one path op)
    // Vectors grouped into logical drawings/captions: path ops of one marked-content
    // block (e.g. a vectorized caption = one /Figure block) — or, when untagged,
    // adjacent same-colour glyphs on a line — are merged into a single SVG.
    function  VectorGroupsCount(PageIndex: Integer): Integer;
    procedure ExportVectorGroup(PageIndex, GroupIndex: Integer; const FileName: string);  // -> .SVG (whole caption)
    function  JpegsCount(PageIndex: Integer): Integer;  // # of JPEG images
    function  ImagesCount(PageIndex: Integer): Integer;  // # of non-JPEG raster images
    procedure ExportJpeg(PageIndex, Index: Integer; const FileName: string);  // -> .jpg
    procedure ExportImage(PageIndex, Index: Integer; const FileName: string);  // -> .png
    procedure DrawRect(PageIndex: Integer; X, Y, W, H: Double; Color: TColor);
    procedure RenderPageToPng(PageIndex: Integer; const FileName: string);
    procedure Zoom(Scale: Extended);
    procedure ImportPDF(Str: TStream; PageFrom, PageTo, ImportAfterPage: Integer);
    property Pages: TObjectList read FPages;
  end;

implementation

uses PdfCFF, PdfBitmapRenderer, PdfJpeg, FPImage, FPWriteJPEG;  // added-API helpers

function IsWhite(C: Byte): Boolean;
begin
  Result := C in [0,9,10,12,13,32];
end;
function IsDelim(C: Byte): Boolean;
begin
  Result := C in [Ord('('),Ord(')'),Ord('<'),Ord('>'),Ord('['),Ord(']'),Ord('{'),Ord('}'),Ord('/'),Ord('%')];
end;
function BytesToAnsi(const A: TPdfBytes): AnsiString;
var I: Integer;
begin
  Result := '';
  SetLength(Result, Length(A));
  for I:=0 to High(A) do Result[I+1]:=AnsiChar(A[I]);
end;
function SliceBytes(const A: TPdfBytes; Start, Count: Integer): TPdfBytes;
begin
  Result := nil;
  SetLength(Result, Count);
  if Count > 0 then Move(A[Start], Result[0], Count);
end;

// =- Type-4 (PostScript calculator) function support =-=-=-=-=-=-=-=-=-=-=-=-─
// A node in a parsed PostScript calculator program. A program is a procedure
// (Children) made of numbers, operators, and nested procedures ({ ... }).
type
  PPSNum = ^Double;
  TPSNodeKind = (psnNum, psnOp, psnProc);
  TPSNode = class
    Kind: TPSNodeKind;
    Num: Double;
    Op: string;
    Children: TList;  // of TPSNode (when Kind=psnProc)
    destructor Destroy;
    override;
  end;

destructor TPSNode.Destroy;
var I: Integer;
begin
  if Assigned(Children) then
  begin
    for I := 0 to Children.Count-1 do TPSNode(Children[I]).Free;
    Children.Free;
  end;
  inherited Destroy;
end;

// Parse a PostScript calculator program from text. P is advanced past the
// matching '}'. Call initially after the opening '{'. Returns a psnProc node.
function PSParseProc(const S: AnsiString; var P: Integer): TPSNode;
var Node, Child: TPSNode;
  Tok: string;
  C: AnsiChar;
  Start, ValCode: Integer;
  D: Double;
begin
  Node := TPSNode.Create;
  Node.Kind := psnProc;
  Node.Children := TList.Create;
  while P <= Length(S) do
  begin
    C := S[P];
    if C in [' ', #9, #10, #13, #12, #0] then begin
      Inc(P);
      Continue;
    end;
    if C = '}' then begin
      Inc(P);
      Break;
    end;
    if C = '{' then
    begin
      Inc(P);
      Child := PSParseProc(S, P);
      Node.Children.Add(Child);
      Continue;
    end;
    // Read a token (number or operator name) up to whitespace/brace.
    Start := P;
    while (P <= Length(S)) and not (S[P] in [' ', #9, #10, #13, #12, #0, '{', '}']) do Inc(P);
    Tok := Copy(S, Start, P - Start);
    if Tok = '' then Continue;
    Child := TPSNode.Create;
    Val(Tok, D, ValCode);  // Val uses '.' decimal regardless of locale
    if ValCode = 0 then
    begin
      Child.Kind := psnNum;
      Child.Num := D;
    end
    else
    begin
      Child.Kind := psnOp;
      Child.Op := LowerCase(Tok);
    end;
    Node.Children.Add(Child);
  end;
  Result := Node;
end;

// Execute a PostScript calculator procedure against a numeric stack.
procedure PSExec(Node: TPSNode; Stk: TList);  // Stk holds boxed Doubles via PDouble
  function Pop: Double;
  var pd: PPSNum;
  begin
    if Stk.Count = 0 then begin
      Result := 0;
      Exit;
    end;
    pd := PPSNum(Stk[Stk.Count-1]);
    Result := pd^;
    Dispose(pd);
    Stk.Delete(Stk.Count-1);
  end;
  procedure Push(V: Double);
  var pd: PPSNum;
  begin
    New(pd);
    pd^ := V;
    Stk.Add(pd);
  end;
  function PeekIdx(FromTop: Integer): Double;
  var pd: PPSNum;
  begin
      pd := PPSNum(Stk[Stk.Count-1-FromTop]);
      Result := pd^;
    end;
var
  I, J, N, Jr: Integer;
  a, b: Double;
  Op: string;
  proc1, proc2: TPSNode;
  tmp: array of Double;
begin
  proc1 := nil;
  proc2 := nil;
  I := 0;
  while I < Node.Children.Count do
  begin
    with TPSNode(Node.Children[I]) do
    begin
      case Kind of
        psnNum: Push(Num);
        psnProc:
          begin
            // Remember up to two pending procedures for if / ifelse.
            proc1 := proc2;
            proc2 := TPSNode(Node.Children[I]);
          end;
        psnOp:
          begin
            Op := TPSNode(Node.Children[I]).Op;
            if Op = 'add' then begin
              b:=Pop;
              a:=Pop;
              Push(a+b);
            end
            else if Op = 'sub' then begin
              b:=Pop;
              a:=Pop;
              Push(a-b);
            end
            else if Op = 'mul' then begin
              b:=Pop;
              a:=Pop;
              Push(a*b);
            end
            else if Op = 'div' then begin
              b:=Pop;
              a:=Pop;
              if b<>0 then Push(a/b) else Push(0);
            end
            else if Op = 'idiv' then begin
              b:=Pop;
              a:=Pop;
              if b<>0 then Push(Trunc(a)/Trunc(b)*0 + (Trunc(a) div Trunc(b))) else Push(0);
            end
            else if Op = 'mod' then begin
              b:=Pop;
              a:=Pop;
              if Trunc(b)<>0 then Push(Trunc(a) mod Trunc(b)) else Push(0);
            end
            else if Op = 'neg' then Push(-Pop)
            else if Op = 'abs' then Push(Abs(Pop))
            else if Op = 'sqrt' then begin
              a:=Pop;
              if a<0 then a:=0;
              Push(Sqrt(a));
            end
            else if Op = 'sin' then Push(Sin(Pop*Pi/180))
            else if Op = 'cos' then Push(Cos(Pop*Pi/180))
            else if Op = 'atan' then begin
              b:=Pop;
              a:=Pop;
              a:=ArcTan2(a,b)*180/Pi;
              if a<0 then a:=a+360;
              Push(a);
            end
            else if Op = 'exp' then begin
              b:=Pop;
              a:=Pop;
              if a<=0 then Push(0) else Push(Exp(b*Ln(a)));
            end
            else if Op = 'ln' then begin
              a:=Pop;
              if a<=0 then Push(0) else Push(Ln(a));
            end
            else if Op = 'log' then begin
              a:=Pop;
              if a<=0 then Push(0) else Push(Ln(a)/Ln(10));
            end
            else if Op = 'cvi' then Push(Trunc(Pop))
            else if Op = 'cvr' then Push(Pop)
            else if Op = 'truncate' then Push(Trunc(Pop))
            else if Op = 'round' then Push(Round(Pop))
            else if Op = 'floor' then Push(Int(Floor(Pop)))
            else if Op = 'ceiling' then Push(Int(Ceil(Pop)))
            else if Op = 'dup' then begin
              a:=Pop;
              Push(a);
              Push(a);
            end
            else if Op = 'pop' then Pop
            else if Op = 'exch' then begin
              b:=Pop;
              a:=Pop;
              Push(b);
              Push(a);
            end
            else if Op = 'index' then
            begin
              N := Trunc(Pop);
              if (N >= 0) and (N < Stk.Count) then Push(PeekIdx(N)) else Push(0);
            end
            else if Op = 'copy' then
            begin
              N := Trunc(Pop);
              if (N > 0) and (N <= Stk.Count) then
              begin
                SetLength(tmp, N);
                for J := 0 to N-1 do tmp[J] := PeekIdx(N-1-J);
                for J := 0 to N-1 do Push(tmp[J]);
              end;
            end
            else if Op = 'roll' then
            begin
              Jr := Trunc(Pop);
              N := Trunc(Pop);
              if (N > 0) and (N <= Stk.Count) then
              begin
                SetLength(tmp, N);
                for J := 0 to N-1 do tmp[J] := PeekIdx(N-1-J);  // tmp[0]=bottom of region
                for J := 0 to N-1 do Pop;
                Jr := ((Jr mod N) + N) mod N;  // normalise rotation
                for J := 0 to N-1 do Push(tmp[((J - Jr) mod N + N) mod N]);
              end;
            end
            else if Op = 'eq' then begin
              b:=Pop;
              a:=Pop;
              if a=b then Push(1) else Push(0);
            end
            else if Op = 'ne' then begin
              b:=Pop;
              a:=Pop;
              if a<>b then Push(1) else Push(0);
            end
            else if Op = 'gt' then begin
              b:=Pop;
              a:=Pop;
              if a>b then Push(1) else Push(0);
            end
            else if Op = 'ge' then begin
              b:=Pop;
              a:=Pop;
              if a>=b then Push(1) else Push(0);
            end
            else if Op = 'lt' then begin
              b:=Pop;
              a:=Pop;
              if a<b then Push(1) else Push(0);
            end
            else if Op = 'le' then begin
              b:=Pop;
              a:=Pop;
              if a<=b then Push(1) else Push(0);
            end
            else if Op = 'and' then begin
              b:=Pop;
              a:=Pop;
              Push(Trunc(a) and Trunc(b));
            end
            else if Op = 'or'  then begin
              b:=Pop;
              a:=Pop;
              Push(Trunc(a) or Trunc(b));
            end
            else if Op = 'not' then begin
              a:=Pop;
              if a=0 then Push(1) else Push(0);
            end
            else if Op = 'true' then Push(1)
            else if Op = 'false' then Push(0)
            else if Op = 'if' then
            begin
              a := Pop;
              if (a <> 0) and Assigned(proc2) then PSExec(proc2, Stk);
              proc1 := nil;
              proc2 := nil;
            end
            else if Op = 'ifelse' then
            begin
              a := Pop;
              if (a <> 0) then begin
                if Assigned(proc1) then PSExec(proc1, Stk);
              end
              else begin
                if Assigned(proc2) then PSExec(proc2, Stk);
              end;
              proc1 := nil;
              proc2 := nil;
            end;
            // unknown operators are ignored
          end;
      end;
    end;
    Inc(I);
  end;
end;

constructor TPdfTextElement.Create;
begin
  inherited Create;
  Kind := pekText;
  Matrix := PdfIdentityMatrix;
end;
constructor TPdfImageElement.Create(AKind: TPdfPageElementKind);
begin
  inherited Create;
  Kind := AKind;
  Matrix := PdfIdentityMatrix;
  BitsPerComponent := 8;
end;
constructor TPdfUnknownElement.Create(const Op: string);
begin
  inherited Create;
  Kind := pekUnknown;
  OperatorName := Op;
  Matrix := PdfIdentityMatrix;
end;
constructor TPdfPathElement.Create;
begin
  inherited Create;
  Kind := pekPath;
  Matrix := PdfIdentityMatrix;
  LineWidth := 1;
end;
constructor TPdfPage.Create;
begin
  inherited Create;
  Elements := TObjectList.Create(True);
  SoftMasks := TObjectList.Create(True);
  ClipPaths := TObjectList.Create(True);
  MediaBox.X1 := 0;
  MediaBox.Y1 := 0;
  MediaBox.X2 := 612;
  MediaBox.Y2 := 792;
  CropBox := MediaBox;
  Width := 612;
  Height := 792;
end;
destructor TPdfPage.Destroy;
begin
  Elements.Free;
  SoftMasks.Free;
  ClipPaths.Free;
  inherited Destroy;
end;
procedure TPdfPage.EnsureParsed;
begin
  if Parsed then Exit;
  Parsed := True;  // set before parsing so re-entrancy (forms/masks) can't loop
  if Assigned(OwnerDoc) and Assigned(PageDict) then
    TPdfDocument(OwnerDoc).ParsePageContent(Self, PageDict, Resources);
end;

destructor TPdfSoftMask.Destroy;
begin
  MaskImage.Free;
  inherited Destroy;
end;

function TPdfSoftMask.AlphaAt(PageX, PageY: Double): Double;
var det, u, v, ex, ey: Double;
  col, row: Integer;
begin
  Result := 0;
  if not Valid or not Built or (W <= 0) or (H <= 0) then Exit;
  det := Matrix.A*Matrix.D - Matrix.B*Matrix.C;
  if Abs(det) < 1e-9 then Exit;
  ex := PageX - Matrix.E;
  ey := PageY - Matrix.F;
  u := (ex*Matrix.D - ey*Matrix.C) / det;
  v := (-ex*Matrix.B + ey*Matrix.A) / det;
  if (u < 0) or (u >= 1) or (v < 0) or (v >= 1) then Exit;  // outside mask -> 0
  col := Trunc(u * W);
  row := Trunc((1 - v) * H);
  if col < 0 then col := 0;
  if col >= W then col := W-1;
  if row < 0 then row := 0;
  if row >= H then row := H-1;
  Result := GrayData[row*W + col] / 255;
end;

constructor TPdfDocument.Create;
begin
  inherited Create;
  FPages := TObjectList.Create(True);
  FObjectCache := TFPHashObjectList.Create(True);
  FRenderZoom := 1.0;
    FSecurity := nil;
    FEncryptReady := False;
    FEncryptObjNum := -1;
    FDecOn := False;
    FPassword := '';
  end;
destructor TPdfDocument.Destroy;
begin
  FSecurity.Free;
  FTrailer.Free;
  FObjectCache.Free;
  FPages.Free;
  FImported.Free;
  inherited Destroy;
end;

procedure TPdfDocument.Assign(Doc: TPdfDocument);
begin
  // =- Reset all previously parsed state =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
  FTrailer.Free;
  FTrailer := nil;
  FObjectCache.Free;
  FObjectCache := TFPHashObjectList.Create(True);
  FreeAndNil(FSecurity);
  FEncryptReady := False;
  FEncryptObjNum := -1;
  FDecOn := False;
  FPages.Clear;
  SetLength(FXRef, 0);

  // =- Copy the raw bytes as an independent buffer =-=-=-=-=-=-=-=-=-=-=-=-=-─
  SetLength(FData, Length(Doc.FData));
  if Length(FData) > 0 then
    Move(Doc.FData[0], FData[0], Length(FData));

  // =- Re-parse exactly as LoadFromFile does =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
  ParseXRef;
  SetupEncryption;
  BuildPages;
  SyncPageArrays;
end;

function TPdfDocument.DataLength: Integer;
begin
  Result := Length(FData);
end;
function TPdfDocument.B(Pos: Integer): Byte;
begin
  if (Pos < 0) or (Pos >= DataLength) then Result := 0 else Result := FData[Pos];
end;

procedure TPdfDocument.LoadFromFile(const FileName: string);
var FS: TBufferedFileStream;
begin
  // Reset any previously parsed state so reloads (e.g. a password retry) are clean.
  // FPassword is intentionally preserved (the password overload sets it first).
  FTrailer.Free;
  FTrailer := nil;
  FObjectCache.Free;
  FObjectCache := TFPHashObjectList.Create(True);
  FreeAndNil(FSecurity);
  FEncryptReady := False;
  FEncryptObjNum := -1;
  FDecOn := False;
  FPages.Clear;
  SetLength(FXRef, 0);
  FS := TBufferedFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(FData, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(FData[0], FS.Size);
  finally
    FS.Free;
  end;
  ParseXRef;
  SetupEncryption;
  BuildPages;
  SyncPageArrays;
end;

procedure TPdfDocument.LoadFromFile(const FileName: string; const Password: string);
begin
  FPassword := Password;
  LoadFromFile(FileName);
end;

procedure TPdfDocument.SetPassword(const Password: string);
begin
  FPassword := Password;
end;

function TPdfDocument.IsEncrypted: Boolean;
begin
  Result := Assigned(FSecurity);
end;

function TPdfDocument.IsAuthenticated: Boolean;
begin
  Result := (not Assigned(FSecurity)) or FSecurity.Authenticated;
end;

procedure TPdfDocument.LoadFromStream(AStream: TStream);
var Remaining: Int64;
begin
  // Reset parsed state (same as Assign)
  FTrailer.Free;
  FTrailer := nil;
  FObjectCache.Free;
  FObjectCache := TFPHashObjectList.Create(True);
  FreeAndNil(FSecurity);
  FEncryptReady := False;
  FEncryptObjNum := -1;
  FDecOn := False;
  FPages.Clear;
  SetLength(FXRef, 0);
  // Read remaining bytes from the current stream position
  Remaining := AStream.Size - AStream.Position;
  SetLength(FData, Remaining);
  if Remaining > 0 then AStream.ReadBuffer(FData[0], Remaining);
  ParseXRef;
  SetupEncryption;
  BuildPages;
  SyncPageArrays;
end;

procedure TPdfDocument.SkipWs(var Pos: Integer);
begin
  while Pos < DataLength do begin
    if B(Pos) = Ord('%') then begin
      while (Pos < DataLength) and not (B(Pos) in [10,13]) do Inc(Pos);
    end
    else if IsWhite(B(Pos)) then Inc(Pos) else Break;
  end;
end;
function TPdfDocument.Match(Pos: Integer; const S: AnsiString): Boolean;
var I: Integer;
begin
  Result := Pos + Length(S) <= DataLength;
  if not Result then Exit;
  for I := 1 to Length(S) do if B(Pos + I - 1) <> Ord(S[I]) then Exit(False);
end;
function TPdfDocument.ReadToken(var Pos: Integer): string;
var S, Len, I: Integer;
begin
  SkipWs(Pos);
  S := Pos;
  while (Pos < DataLength) and not IsWhite(B(Pos)) and not IsDelim(B(Pos)) do Inc(Pos);
  // Build result directly from FData bytes — avoids copying the entire file.
  Len := Pos - S;
  SetLength(Result, Len);
  for I := 0 to Len - 1 do
    Result[I + 1] := Chr(FData[S + I]);
end;

function TPdfDocument.ParseName(var Pos: Integer): TPdfNameObject;
var S, Len, I: Integer;
  N: string;
begin
  Inc(Pos);
  S := Pos;
  while (Pos < DataLength) and not IsWhite(B(Pos)) and not IsDelim(B(Pos)) do Inc(Pos);
  Len := Pos-S;
  SetLength(N, Len);
  for I := 0 to Len-1 do N[I+1] := Chr(FData[S+I]);
  Result := TPdfNameObject.Create(N);
end;
function TPdfDocument.ParseLiteralString(var Pos: Integer): TPdfStringObject;
var S: AnsiString;
  D: Integer;
  C, E: Byte;
  oct, n: Integer;
begin
  Inc(Pos);
  D := 1;
  S := '';
  while (Pos < DataLength) and (D > 0) do begin
    C := B(Pos);
    if C = Ord('\') then
    begin
      // Full PDF escape handling (needed so /O,/U key material decodes exactly).
      Inc(Pos);
      if Pos >= DataLength then Break;
      E := B(Pos);
      case E of
        Ord('n'): begin
          S := S + #10;
          Inc(Pos);
        end;
        Ord('r'): begin
          S := S + #13;
          Inc(Pos);
        end;
        Ord('t'): begin
          S := S + #9;
          Inc(Pos);
        end;
        Ord('b'): begin
          S := S + #8;
          Inc(Pos);
        end;
        Ord('f'): begin
          S := S + #12;
          Inc(Pos);
        end;
        Ord('('): begin
          S := S + '(';
          Inc(Pos);
        end;
        Ord(')'): begin
          S := S + ')';
          Inc(Pos);
        end;
        Ord('\'): begin
          S := S + '\';
          Inc(Pos);
        end;
        10: Inc(Pos);  // backslash-LF: line continuation
        13: begin
          Inc(Pos);
          if (Pos < DataLength) and (B(Pos)=10) then Inc(Pos);
        end;
        Ord('0')..Ord('7'):                              // 1..3 octal digits
          begin
            oct := 0;
            n := 0;
            while (n < 3) and (Pos < DataLength) and (B(Pos) in [Ord('0')..Ord('7')]) do
            begin
              oct := oct*8 + (B(Pos)-Ord('0'));
              Inc(Pos);
              Inc(n);
            end;
            S := S + AnsiChar(Byte(oct));
          end;
      else
        begin
          S := S + AnsiChar(E);
          Inc(Pos);
        end;  // unknown escape: keep char
      end;
    end
    else if C = Ord('(') then begin
      Inc(D);
      S := S + '(';
      Inc(Pos);
    end
    else if C = Ord(')') then begin
      Dec(D);
      if D > 0 then S := S + ')';
      Inc(Pos);
    end
    else begin
      S := S + AnsiChar(C);
      Inc(Pos);
    end;
  end;
  Result := TPdfStringObject.Create(DecStr(S));
end;
// Hex strings carry RAW bytes (the value is the decoded hex). Decrypt those bytes.
function HexNibble(C: Byte): Integer;
begin
  case C of
    Ord('0')..Ord('9'): Result := C - Ord('0');
    Ord('a')..Ord('f'): Result := C - Ord('a') + 10;
    Ord('A')..Ord('F'): Result := C - Ord('A') + 10;
  else Result := 0;
  end;
end;
function TPdfDocument.ParseHexString(var Pos: Integer): TPdfStringObject;
var S: AnsiString;
  hi: Integer;
  haveHi: Boolean;
  c: Byte;
begin
  Inc(Pos);
  S := '';
  hi := 0;
  haveHi := False;
  while (Pos < DataLength) and (B(Pos) <> Ord('>')) do
  begin
    c := B(Pos);
    if not IsWhite(c) then
    begin
      if haveHi then begin
        S := S + AnsiChar((hi shl 4) or HexNibble(c));
        haveHi := False;
      end
      else begin
        hi := HexNibble(c);
        haveHi := True;
      end;
    end;
    Inc(Pos);
  end;
  if haveHi then S := S + AnsiChar(hi shl 4);  // odd nibble count: pad low nibble with 0
  if Pos < DataLength then Inc(Pos);
  Result := TPdfStringObject.Create(DecStr(S));
end;
function TPdfDocument.DecStr(const S: AnsiString): AnsiString;
var inb, outb: TPdfBytes;
  i: Integer;
begin
  if not (FDecOn and Assigned(FSecurity)) then Exit(S);
  SetLength(inb, Length(S));
  for i := 1 to Length(S) do inb[i-1] := Byte(S[i]);
  outb := FSecurity.Decrypt(inb, FDecNum, FDecGen, True);
  SetLength(Result, Length(outb));
  for i := 0 to High(outb) do Result[i+1] := AnsiChar(outb[i]);
end;
function TPdfDocument.ParseArray(var Pos: Integer): TPdfArrayObject;
var O: TPdfObject;
begin
  Result := TPdfArrayObject.Create;
  Inc(Pos);
  while Pos < DataLength do begin
    SkipWs(Pos);
    if B(Pos) = Ord(']') then begin
      Inc(Pos);
      Break;
    end;
    O := ParseDirectObject(Pos);
    if Assigned(O) then Result.Items.Add(O) else Break;
  end;
end;
function TPdfDocument.ParseDictionary(var Pos: Integer): TPdfDictionaryObject;
var Key: TPdfNameObject;
  Val, LenObj: TPdfObject;
  D: TPdfDictionaryObject;
  SObj: TPdfStreamObject;
  L, Start: Integer;
begin
  D := TPdfDictionaryObject.Create;
  Inc(Pos,2);
  while Pos < DataLength do begin
    SkipWs(Pos);
    if Match(Pos,'>>') then begin
      Inc(Pos,2);
      Break;
    end;
    Key := ParseName(Pos);
    Val := ParseDirectObject(Pos);
    D.Add(Key.Value, Val);
    Key.Free;
  end;
  SkipWs(Pos);
  if Match(Pos,'stream') then begin
    SObj := TPdfStreamObject.Create;
    while D.Keys.Count > 0 do begin
      SObj.Add(D.Keys[0], TPdfObject(D.Keys.Objects[0]));
      D.Keys.Objects[0] := nil;
      D.Keys.Delete(0);
    end;
    D.Free;
    Inc(Pos,6);
    if Match(Pos,#13#10) then Inc(Pos,2) else if Match(Pos,#10) or Match(Pos,#13) then Inc(Pos);
    Start := Pos;
    LenObj := ResolveObject(SObj.Get('Length'));
    if Assigned(LenObj) then L := Trunc(LenObj.AsNumber) else L := 0;
    SObj.RawData := SliceBytes(FData, Start, L);
    Inc(Pos, L);
    SkipWs(Pos);
    if Match(Pos,'endstream') then Inc(Pos,9);
    // Encrypted streams are decrypted (per object) BEFORE their /Filter is applied.
    // XRef streams load with decryption off (FDecOn false), so they pass through.
    if FDecOn and Assigned(FSecurity) then
      SObj.RawData := FSecurity.Decrypt(SObj.RawData, FDecNum, FDecGen, False);
    SObj.DecodedData := DecodeStream(SObj);
    Result := SObj;
  end else Result := D;
end;
function TPdfDocument.ParseNumberOrReference(var Pos: Integer): TPdfObject;
var P2, N1, N2, ErrCode: Integer;
  T1,T2,T3: string;
  V: Double;
begin
  T1 := ReadToken(Pos);
  P2 := Pos;
  T2 := ReadToken(P2);
  T3 := ReadToken(P2);
  if TryStrToInt(T1,N1) and TryStrToInt(T2,N2) and (T3='R') then begin
    Pos := P2;
    Exit(TPdfReferenceObject.Create(N1,N2));
  end;
  Val(T1, V, ErrCode);
  if System.Pos('.',T1)>0 then Result := TPdfNumberObject.Create(V,pokReal) else Result := TPdfNumberObject.Create(V,pokInteger);
end;
function TPdfDocument.ParseDirectObject(var Pos: Integer): TPdfObject;
var T: string;
begin
  SkipWs(Pos);
  if Pos >= DataLength then Exit(nil);
  case Chr(B(Pos)) of
    '/': Result := ParseName(Pos);
    '(': Result := ParseLiteralString(Pos);
    '[': Result := ParseArray(Pos);
    '<': if Match(Pos,'<<') then Result := ParseDictionary(Pos) else Result := ParseHexString(Pos);
  else
    T := ReadToken(Pos);
    Dec(Pos, Length(T));
    if T='null' then begin
      Inc(Pos,4);
      Result := TPdfObject.Create;
      Result.Kind := pokNull;
    end
    else if T='true' then begin
      Inc(Pos,4);
      Result := TPdfNumberObject.Create(1,pokBoolean);
    end
    else if T='false' then begin
      Inc(Pos,5);
      Result := TPdfNumberObject.Create(0,pokBoolean);
    end
    else Result := ParseNumberOrReference(Pos);
  end;
end;
function TPdfDocument.ParseObjectAt(var Pos: Integer): TPdfObject;
begin
  ReadToken(Pos);
  ReadToken(Pos);
  if ReadToken(Pos) <> 'obj' then raise Exception.Create('Expected obj');
  Result := ParseDirectObject(Pos);
  SkipWs(Pos);
  if Match(Pos,'endobj') then Inc(Pos,6);
end;

function TPdfDocument.FindStartXRef: Int64;
var S: AnsiString;
  I: Integer;
begin
  S := BytesToAnsi(FData);
  Result := -1;
  for I := Length(S)-9 downto 1 do if Copy(S,I,9)='startxref' then Exit(I-1);
end;
procedure TPdfDocument.EnsureXRefSize(N: Integer);
begin
  if Length(FXRef) <= N then SetLength(FXRef, N+1);
end;

// Store an xref entry honouring section precedence: the first (newest) section to
// define a slot wins. The lone exception is a hybrid /XRefStm, which is allowed to
// replace the free placeholders that the classic table of the same update leaves
// behind for objects that actually live inside object streams.
procedure TPdfDocument.SetXRefEntry(Index: Integer; const Entry: TPdfXRefEntry);
begin
  EnsureXRefSize(Index);
  if FXRef[Index].Defined then
    if not (FXRefOverrideFree and (FXRef[Index].Kind = xrekFree) and (Entry.Kind <> xrekFree)) then
      Exit;
  FXRef[Index] := Entry;
  FXRef[Index].Defined := True;
end;

procedure TPdfDocument.ParseXRef;
var P: Integer;
  Off: Int64;
begin
  P := FindStartXRef;
  if P < 0 then raise Exception.Create('startxref not found');
  Inc(P,9);
  SkipWs(P);
  Off := StrToInt64Def(ReadToken(P),-1);
  if Off < 0 then raise Exception.Create('bad startxref');
  SetLength(FXRefVisited, 0);
  ProcessXRefSection(Off);
  if not Assigned(FTrailer) then raise Exception.Create('no xref trailer found');
end;

// Parse the xref section at byte offset Off, then follow its /XRefStm (hybrid
// compressed-object table) and /Prev (older section) so the whole cross-reference
// chain is indexed. Linearized and incrementally-updated PDFs depend on this.
procedure TPdfDocument.ProcessXRefSection(Off: Int64);
var P, ObjNum, I: Integer;
  Tok: string;
    Trailer: TPdfDictionaryObject;
    Obj: TPdfObject;
    Stream: TPdfStreamObject;
    PrevOff, StmOff: Int64;
begin
  if Off < 0 then Exit;
  if Off >= DataLength then Exit;
  for I := 0 to High(FXRefVisited) do if FXRefVisited[I] = Off then Exit;  // loop guard
  SetLength(FXRefVisited, Length(FXRefVisited)+1);
  FXRefVisited[High(FXRefVisited)] := Off;

  P := Off;
  Tok := ReadToken(P);
  if Tok = 'xref' then begin
    Trailer := nil;
    ParseClassicXRef(P, Trailer);
    if not Assigned(Trailer) then Exit;
    StmOff := Trunc(Trailer.GetNumber('XRefStm', -1));
    PrevOff := Trunc(Trailer.GetNumber('Prev', -1));
    if not Assigned(FTrailer) then FTrailer := Trailer   // keep newest trailer (owns it)
    else Trailer.Free;
    // Hybrid companion stream first so its compressed entries override classic free slots.
    if StmOff >= 0 then begin
      FXRefOverrideFree := True;
      try
        ProcessXRefSection(StmOff);
      finally
        FXRefOverrideFree := False;
      end;
    end;
    if PrevOff >= 0 then ProcessXRefSection(PrevOff);
  end
  else begin
    P := Off;
    ObjNum := StrToIntDef(ReadToken(P),0);
    ReadToken(P);
    if ReadToken(P) <> 'obj' then Exit;
    Obj := ParseDirectObject(P);
    if Obj is TPdfStreamObject then begin
      Stream := TPdfStreamObject(Obj);
      PrevOff := Trunc(Stream.GetNumber('Prev', -1));
      ParseXRefStreamAt(ObjNum, Stream);
      if not Assigned(FTrailer) then FTrailer := Stream   // keep newest trailer (owns it)
      else Stream.Free;
      if PrevOff >= 0 then ProcessXRefSection(PrevOff);
    end
    else Obj.Free;
  end;
end;

procedure TPdfDocument.ParseClassicXRef(var Pos: Integer; out Trailer: TPdfDictionaryObject);
var First, Count, I, J: Integer;
  TrailerObj: TPdfObject;
    Off: Int64;
    Gen: Integer;
    IsInUse: Boolean;
    Entry: TPdfXRefEntry;
begin
  Trailer := nil;
  while True do begin
    SkipWs(Pos);
    if Match(Pos,'trailer') then begin
      Inc(Pos,7);
      TrailerObj := ParseDirectObject(Pos);
      if TrailerObj is TPdfDictionaryObject then Trailer := TPdfDictionaryObject(TrailerObj) else TrailerObj.Free;
      Break;
    end;
    if not ((Pos < DataLength) and (B(Pos) >= Ord('0')) and (B(Pos) <= Ord('9'))) then Break;  // not a subsection header
    First := StrToIntDef(ReadToken(Pos),0);
    Count := StrToIntDef(ReadToken(Pos),0);
    EnsureXRefSize(First+Count);
    for I := 0 to Count-1 do begin
      // Read the 20-byte xref entry directly from FData — no full-file AnsiString copy.
      // Format: "nnnnnnnnnn ggggg n/f \r\n"  (10-digit offset, space, 5-digit gen, space, n/f, eol)
      SkipWs(Pos);
      Off := 0;
      for J := 0 to 9 do if (Pos+J < DataLength) and (FData[Pos+J] >= Ord('0')) then Off := Off*10 + (FData[Pos+J]-Ord('0'));
      Gen := 0;
      for J := 0 to 4 do if (Pos+11+J < DataLength) and (FData[Pos+11+J] >= Ord('0')) then Gen := Gen*10 + (FData[Pos+11+J]-Ord('0'));
      IsInUse := (Pos+17 < DataLength) and (FData[Pos+17] = Ord('n'));
      FillChar(Entry, SizeOf(Entry), 0);
      if IsInUse then begin
        Entry.Kind := xrekUncompressed;
        Entry.Offset := Off;
        Entry.Generation := Gen;
      end
      else Entry.Kind := xrekFree;
      SetXRefEntry(First+I, Entry);
      while (Pos < DataLength) and not (B(Pos) in [10,13]) do Inc(Pos);
      while (Pos < DataLength) and (B(Pos) in [10,13]) do Inc(Pos);
    end;
  end;
end;

function ReadUIntBE(const Data: TPdfBytes; var P: Integer; W: Integer): Int64;
var I: Integer;
begin
  Result := 0;
  for I := 1 to W do begin
    Result := Result shl 8;
    if P < Length(Data) then Result := Result + Data[P];
    Inc(P);
  end;
end;

procedure TPdfDocument.ParseXRefStreamAt(ObjNum: Integer; Stream: TPdfStreamObject);
var WObj, IndexObj: TPdfObject;
  WArr, IdxArr: TPdfArrayObject;
  W0,W1,W2: Integer;
  Data: TPdfBytes;
  P, Pair, First, Count, I: Integer;
  T,F2,F3: Int64;
  Entry: TPdfXRefEntry;
begin
  // Caller owns Stream and decides whether it becomes FTrailer; this routine only
  // fills the cross-reference table from the stream's data.
  WObj := ResolveObject(Stream.Get('W'));
  if not (WObj is TPdfArrayObject) then Exit;
  WArr := TPdfArrayObject(WObj);
  W0 := Trunc(TPdfObject(WArr.Items[0]).AsNumber);
  W1 := Trunc(TPdfObject(WArr.Items[1]).AsNumber);
  W2 := Trunc(TPdfObject(WArr.Items[2]).AsNumber);
  Data := Stream.DecodedData;
  P := 0;
  IndexObj := ResolveObject(Stream.Get('Index'));
  if IndexObj is TPdfArrayObject then IdxArr := TPdfArrayObject(IndexObj) else IdxArr := nil;
  Pair := 0;
  repeat
    if Assigned(IdxArr) then begin
      First := Trunc(TPdfObject(IdxArr.Items[Pair]).AsNumber);
      Count := Trunc(TPdfObject(IdxArr.Items[Pair+1]).AsNumber);
      Inc(Pair,2);
    end
    else begin
      First := 0;
      Count := Trunc(Stream.GetNumber('Size'));
      Pair := 999999;
    end;
    EnsureXRefSize(First+Count);
    for I := 0 to Count-1 do begin
      T := ReadUIntBE(Data,P,W0);
      if W0=0 then T := 1;
      F2 := ReadUIntBE(Data,P,W1);
      F3 := ReadUIntBE(Data,P,W2);
      FillChar(Entry, SizeOf(Entry), 0);
      case T of
        0: Entry.Kind := xrekFree;
        1: begin
          Entry.Kind := xrekUncompressed;
          Entry.Offset := F2;
          Entry.Generation := F3;
        end;
        2: begin
          Entry.Kind := xrekCompressed;
          Entry.ObjStreamNumber := F2;
          Entry.ObjStreamIndex := F3;
        end;
      end;
      SetXRefEntry(First+I, Entry);
    end;
  until (not Assigned(IdxArr)) or (Pair >= IdxArr.Items.Count);
end;

// Reverse a PNG/TIFF predictor applied before Flate/LZW compression. PDF stores
// these parameters in a stream's /DecodeParms; without undoing them the inflated
// bytes (xref streams, object streams, images, content) are unusable.
function ApplyPredictorBytes(const Data: TPdfBytes; Predictor, Colors, BPC, Columns: Integer): TPdfBytes;
var BytesPerPixel, RowLen, NumRows, Row, I, SrcPos, DstPos: Integer;
    a, b, c, p, pa, pb, pc, ft, x: Integer;
    Prev, Cur: TPdfBytes;
begin
  Result := Data;
  BytesPerPixel := (Colors*BPC + 7) div 8;
  if BytesPerPixel < 1 then BytesPerPixel := 1;
  RowLen := (Colors*BPC*Columns + 7) div 8;
  if RowLen < 1 then Exit;

  if Predictor = 2 then begin
    // TIFF predictor 2: horizontal byte differencing (handled for 8-bit components).
    if BPC <> 8 then Exit;
    SetLength(Result, Length(Data));
    if Length(Data) > 0 then Move(Data[0], Result[0], Length(Data));
    NumRows := Length(Result) div RowLen;
    for Row := 0 to NumRows-1 do
      for I := BytesPerPixel to RowLen-1 do begin
        DstPos := Row*RowLen + I;
        Result[DstPos] := Byte((Result[DstPos] + Result[DstPos-BytesPerPixel]) and $FF);
      end;
    Exit;
  end;

  // PNG predictors (10..15): every row is prefixed by a one-byte filter type.
  if Predictor < 10 then Exit;
  NumRows := Length(Data) div (RowLen + 1);
  SetLength(Result, NumRows * RowLen);
  SetLength(Prev, RowLen);
  SetLength(Cur, RowLen);
  for I := 0 to RowLen-1 do Prev[I] := 0;
  SrcPos := 0;
  DstPos := 0;
  for Row := 0 to NumRows-1 do begin
    ft := Data[SrcPos];
    Inc(SrcPos);
    for I := 0 to RowLen-1 do begin
      x := Data[SrcPos];
      Inc(SrcPos);
      if I >= BytesPerPixel then a := Cur[I-BytesPerPixel] else a := 0;
      b := Prev[I];
      if I >= BytesPerPixel then c := Prev[I-BytesPerPixel] else c := 0;
      case ft of
        1: Cur[I] := Byte((x + a) and $FF);
        2: Cur[I] := Byte((x + b) and $FF);
        3: Cur[I] := Byte((x + ((a+b) div 2)) and $FF);
        4: begin
             p := a + b - c;
             pa := Abs(p-a);
             pb := Abs(p-b);
             pc := Abs(p-c);
             if (pa <= pb) and (pa <= pc) then Cur[I] := Byte((x+a) and $FF)
             else if pb <= pc then Cur[I] := Byte((x+b) and $FF)
             else Cur[I] := Byte((x+c) and $FF);
           end;
      else Cur[I] := Byte(x and $FF);
      end;
    end;
    if RowLen > 0 then begin
      Move(Cur[0], Result[DstPos], RowLen);
      Move(Cur[0], Prev[0], RowLen);
    end;
    Inc(DstPos, RowLen);
  end;
end;

// Apply the predictor named in Parms, but only for the compression filters that use one.
function ApplyStreamPredictor(const FilterName: string; const Data: TPdfBytes; Parms: TPdfDictionaryObject): TPdfBytes;
var Predictor, Colors, BPC, Columns: Integer;
begin
  Result := Data;
  if not Assigned(Parms) then Exit;
  if (FilterName <> 'FlateDecode') and (FilterName <> 'Fl') and
     (FilterName <> 'LZWDecode') and (FilterName <> 'LZW') then Exit;
  Predictor := Trunc(Parms.GetNumber('Predictor', 1));
  if Predictor <= 1 then Exit;
  Colors  := Trunc(Parms.GetNumber('Colors', 1));
  BPC     := Trunc(Parms.GetNumber('BitsPerComponent', 8));
  Columns := Trunc(Parms.GetNumber('Columns', 1));
  Result := ApplyPredictorBytes(Data, Predictor, Colors, BPC, Columns);
end;

function TPdfDocument.DecodeStream(Stream: TPdfStreamObject): TPdfBytes;
var FO, PO, X, PItem: TPdfObject;
  FArr, PArr: TPdfArrayObject;
  I: Integer;
  Parms: TPdfDictionaryObject;
begin
  Result := Stream.RawData;
  FO := ResolveObject(Stream.Get('Filter'));
  if not Assigned(FO) then Exit;
  PO := ResolveObject(Stream.Get('DecodeParms'));
  if not Assigned(PO) then PO := ResolveObject(Stream.Get('DP'));
  if FO.Kind = pokName then begin
    Result := TPdfFilterEngine.ApplyFilter(FO.AsName, Result);
    if PO is TPdfDictionaryObject then Result := ApplyStreamPredictor(FO.AsName, Result, TPdfDictionaryObject(PO));
  end
  else if FO is TPdfArrayObject then begin
    FArr := TPdfArrayObject(FO);
    if PO is TPdfArrayObject then PArr := TPdfArrayObject(PO) else PArr := nil;
    for I := 0 to FArr.Items.Count-1 do begin
      X := ResolveObject(TPdfObject(FArr.Items[I]));
      if Assigned(X) and (X.Kind = pokName) then begin
        Result := TPdfFilterEngine.ApplyFilter(X.AsName, Result);
        Parms := nil;
        if Assigned(PArr) then begin
          if I < PArr.Items.Count then begin
            PItem := ResolveObject(TPdfObject(PArr.Items[I]));
            if PItem is TPdfDictionaryObject then Parms := TPdfDictionaryObject(PItem);
          end;
        end
        else if (FArr.Items.Count = 1) and (PO is TPdfDictionaryObject) then Parms := TPdfDictionaryObject(PO);
        if Assigned(Parms) then Result := ApplyStreamPredictor(X.AsName, Result, Parms);
      end;
    end;
  end;
end;

function TPdfDocument.ResolveObject(Obj: TPdfObject): TPdfObject;
begin
  if Assigned(Obj) and (Obj.Kind=pokReference) then Result := LoadIndirectObject(TPdfReferenceObject(Obj).ObjectNumber) else Result := Obj;
end;
function TPdfDocument.LoadIndirectObject(ObjectNumber: Integer): TPdfObject;
var Key: string;
  P: Integer;
  SaveNum, SaveGen: Integer;
  SaveOn: Boolean;
begin
  Key := IntToStr(ObjectNumber);
  Result := TPdfObject(FObjectCache.Find(Key));
  if Assigned(Result) then Exit;
  if (ObjectNumber >= Length(FXRef)) then Exit(nil);
  case FXRef[ObjectNumber].Kind of
    xrekUncompressed:
      begin
        // Set the decryption context to this top-level object. Strings and streams
        // parsed within are decrypted with key(objNum,gen). The /Encrypt dict itself
        // is never decrypted.
        SaveNum := FDecNum;
        SaveGen := FDecGen;
        SaveOn := FDecOn;
        FDecNum := ObjectNumber;
        FDecGen := FXRef[ObjectNumber].Generation;
        FDecOn := FEncryptReady and (ObjectNumber <> FEncryptObjNum);
        try
          P := FXRef[ObjectNumber].Offset;
          Result := ParseObjectAt(P);
        finally
          FDecNum := SaveNum;
          FDecGen := SaveGen;
          FDecOn := SaveOn;
        end;
        FObjectCache.Add(Key, Result);
      end;
    xrekCompressed: begin
      Result := LoadCompressedObject(ObjectNumber);
      if Assigned(Result) then FObjectCache.Add(Key, Result);
    end;
  else Result := nil;
  end;
end;

function TPdfDocument.LoadCompressedObject(ObjectNumber: Integer): TPdfObject;
var OS: TPdfStreamObject;
  ObjStm: TPdfObject;
  N, First, I, P, Num, Off: Integer;
    HeaderPos: Integer;
    SavedData: TPdfBytes;
    SaveOn: Boolean;
begin
  Result := nil;
  ObjStm := LoadIndirectObject(FXRef[ObjectNumber].ObjStreamNumber);
  if not (ObjStm is TPdfStreamObject) then Exit;
  OS := TPdfStreamObject(ObjStm);
  N := Trunc(OS.GetNumber('N'));
  First := Trunc(OS.GetNumber('First'));
  // Parse header and objects from the decoded stream data, not from FData.
  // Objects inside an object stream are NOT individually encrypted — the object
  // stream as a whole was already decrypted when it was loaded — so suppress
  // per-object decryption while reading them.
  SavedData := FData;
  FData := OS.DecodedData;
  SaveOn := FDecOn;
  FDecOn := False;
  try
    HeaderPos := 0;
    for I := 0 to N - 1 do begin
      Num := StrToIntDef(ReadToken(HeaderPos), 0);
      Off := StrToIntDef(ReadToken(HeaderPos), 0);
      if Num = ObjectNumber then begin
        P := First + Off;
        Result := ParseDirectObject(P);
        Exit;
      end;
    end;
  finally
    FData := SavedData;
    FDecOn := SaveOn;
  end;
end;

function TPdfDocument.BuildFontMap(Resources: TPdfDictionaryObject): TFPHashObjectList;
var FontsObj, FontObj, TUObj, WidthsObj, DescObj, FFObj, DescFontsObj: TPdfObject;
  Fonts: TPdfDictionaryObject;
    I, FirstChar: Integer;
    Font: TPdfFont;
    CMap: TPdfCMap;
    FF3Sub: string;
    CodeToUni: array[0..255] of Word;
    cc: Integer; us: UnicodeString; bs: AnsiString; ttData: TPdfBytes;
begin
  Result := TFPHashObjectList.Create(True);
  if not Assigned(Resources) then Exit;
  FontsObj := ResolveObject(Resources.Get('Font'));
  if not (FontsObj is TPdfDictionaryObject) then Exit;
  Fonts := TPdfDictionaryObject(FontsObj);
  for I := 0 to Fonts.Keys.Count - 1 do begin
    FontObj := ResolveObject(TPdfObject(Fonts.Keys.Objects[I]));
    if FontObj is TPdfDictionaryObject then begin
      Font := TPdfFont.Create;
      Font.LoadFromDictionary(TPdfDictionaryObject(FontObj), nil);
      // LoadFromDictionary cannot resolve indirect Widths refs itself; resolve here.
      WidthsObj := ResolveObject(TPdfDictionaryObject(FontObj).Get('Widths'));
      if Assigned(WidthsObj) then
      begin
        FirstChar := Trunc(TPdfDictionaryObject(FontObj).GetNumber('FirstChar', 0));
        Font.LoadWidths(WidthsObj, FirstChar);
      end;
      // ToUnicode maps encoded bytes to Unicode; without it CID text is unreadable.
      TUObj := ResolveObject(TPdfDictionaryObject(FontObj).Get('ToUnicode'));
      if TUObj is TPdfStreamObject then begin
        CMap := TPdfCMap.Create;
        CMap.LoadFromText(BytesToAnsi(TPdfStreamObject(TUObj).DecodedData));
        Font.SetToUnicode(CMap);
      end;
      // The FontDescriptor and its FontFile streams are usually INDIRECT refs that
      // LoadFromDictionary can't dereference itself, so the embedded program never
      // reached the font. Resolve them here for simple fonts (Type1/TrueType). For
      // Type0 the descriptor is on the descendant — left to substitution for now.
      DescObj := ResolveObject(TPdfDictionaryObject(FontObj).Get('FontDescriptor'));
      if DescObj is TPdfDictionaryObject then
      begin
        FFObj := ResolveObject(TPdfDictionaryObject(DescObj).Get('FontFile2'));
        if FFObj is TPdfStreamObject then
        begin
          // An embedded TrueType subset may carry only a Mac/private cmap keyed by
          // the PDF's own content codes (not Unicode), so GDI's Unicode TextOut would
          // draw nothing. Compose the PDF code->Unicode (DecodeSimpleByte, from the
          // font's /ToUnicode+/Encoding) with the font's code->GID cmap into a proper
          // Windows (3,1) cmap so the real embedded glyphs render. No-op if the font
          // already has a (3,x) cmap.
          SetLength(bs, 1);
          for cc := 0 to 255 do
          begin
            bs[1] := AnsiChar(cc);
            us := Font.DecodeString(bs);   // simple fonts decode one byte -> one char
            if Length(us) > 0 then CodeToUni[cc] := Word(us[1]) else CodeToUni[cc] := 0;
          end;
          ttData := EnsureWindowsCmap(TPdfStreamObject(FFObj).DecodedData, CodeToUni);
          Font.SetFontProgramBytes(fpkTrueType, ttData);
        end
        else
        begin
          FFObj := ResolveObject(TPdfDictionaryObject(DescObj).Get('FontFile3'));
          if FFObj is TPdfStreamObject then
          begin
            FF3Sub := TPdfStreamObject(FFObj).GetName('Subtype');
            if SameText(FF3Sub,'Type1C') or SameText(FF3Sub,'CIDFontType0C') or SameText(FF3Sub,'OpenType') then
              Font.SetFontProgramBytes(fpkCFF, TPdfStreamObject(FFObj).DecodedData);
          end;
        end;
      end;
      // Type0/CID: the descendant font carries /W (CID widths) and /DW (default),
      // both usually indirect — resolve them so advances are correct (otherwise
      // every glyph gets the default width and text marches off the line).
      DescFontsObj := ResolveObject(TPdfDictionaryObject(FontObj).Get('DescendantFonts'));
      if (DescFontsObj is TPdfArrayObject) and (TPdfArrayObject(DescFontsObj).Items.Count > 0) then
        DescFontsObj := ResolveObject(TPdfObject(TPdfArrayObject(DescFontsObj).Items[0]));
      if DescFontsObj is TPdfDictionaryObject then
      begin
        FFObj := ResolveObject(TPdfDictionaryObject(DescFontsObj).Get('W'));
        if FFObj is TPdfArrayObject then Font.LoadCIDWidths(FFObj);
        FFObj := ResolveObject(TPdfDictionaryObject(DescFontsObj).Get('DW'));
        if Assigned(FFObj) then Font.SetDefaultWidth(FFObj.AsNumber);
      end;
      Result.Add(Fonts.Keys[I], Font);
    end;
  end;
end;


function RectFromArray(Arr: TPdfArrayObject; const Default: TPdfRect): TPdfRect;
begin
  Result := Default;
  if Assigned(Arr) and (Arr.Items.Count >= 4) then
  begin
    Result.X1 := TPdfObject(Arr.Items[0]).AsNumber;
    Result.Y1 := TPdfObject(Arr.Items[1]).AsNumber;
    Result.X2 := TPdfObject(Arr.Items[2]).AsNumber;
    Result.Y2 := TPdfObject(Arr.Items[3]).AsNumber;
  end;
end;

procedure SetupPageBoxes(Page: TPdfPage; Doc: TPdfDocument; PageDict: TPdfDictionaryObject);
var
  O: TPdfObject;
  R: TPdfRect;
begin
  O := Doc.ResolveObject(PageDict.Get('MediaBox'));
  if O is TPdfArrayObject then
    Page.MediaBox := RectFromArray(TPdfArrayObject(O), Page.MediaBox);

  Page.CropBox := Page.MediaBox;
  O := Doc.ResolveObject(PageDict.Get('CropBox'));
  if O is TPdfArrayObject then
    Page.CropBox := RectFromArray(TPdfArrayObject(O), Page.CropBox);

  R := Page.CropBox;
  Page.Width := Abs(R.X2 - R.X1);
  Page.Height := Abs(R.Y2 - R.Y1);
  if Page.Width <= 0 then Page.Width := 612;
  if Page.Height <= 0 then Page.Height := 792;
end;

// Detect /Encrypt in the trailer, build the standard security handler and
// authenticate (empty password by default, or whatever SetPassword supplied).
// Must run AFTER ParseXRef (so trailer + objects are reachable) and BEFORE any
// content is parsed. Raises EPdfPasswordRequired if the password does not unlock.
procedure TPdfDocument.SetupEncryption;
var EncRef, EncObj, FiltObj: TPdfObject;
  Enc: TPdfDictionaryObject;
    V, R, LenBits: Integer;
    P: LongInt;
    EncMeta: Boolean;
    Stm, Str: TPdfCryptMethod;
    ok: Boolean;

  function StrBytes(D: TPdfDictionaryObject; const Key: string): TPdfBytes;
  var O: TPdfObject;
    s: AnsiString;
    i: Integer;
  begin
    SetLength(Result, 0);
    O := ResolveObject(D.Get(Key));
    if O is TPdfStringObject then
    begin
      s := TPdfStringObject(O).Value;
      SetLength(Result, Length(s));
      for i := 1 to Length(s) do Result[i-1] := Byte(s[i]);
    end;
  end;

  function IDBytes: TPdfBytes;
  var O, E: TPdfObject;
    arr: TPdfArrayObject;
    s: AnsiString;
    i: Integer;
  begin
    SetLength(Result, 0);
    O := ResolveObject(FTrailer.Get('ID'));
    if (O is TPdfArrayObject) and (TPdfArrayObject(O).Items.Count > 0) then
    begin
      arr := TPdfArrayObject(O);
      E := ResolveObject(TPdfObject(arr.Items[0]));
      if E is TPdfStringObject then
      begin
        s := TPdfStringObject(E).Value;
        SetLength(Result, Length(s));
        for i := 1 to Length(s) do Result[i-1] := Byte(s[i]);
      end;
    end;
  end;

  function MethodFor(CF: TPdfDictionaryObject; const Name: string): TPdfCryptMethod;
  var O: TPdfObject;
    cfm: string;
  begin
    if (Name = '') or SameText(Name, 'Identity') then Exit(cmIdentity);
    Result := cmIdentity;
    if not Assigned(CF) then Exit;
    O := ResolveObject(CF.Get(Name));
    if O is TPdfDictionaryObject then
    begin
      cfm := TPdfDictionaryObject(O).GetName('CFM');
      if SameText(cfm, 'V2') then Result := cmRC4
      else if SameText(cfm, 'AESV2') then Result := cmAESV2
      else if SameText(cfm, 'AESV3') then Result := cmAESV3;
    end;
  end;

var CFObj: TPdfObject;
  CF: TPdfDictionaryObject;
  StmName, StrName: string;
begin
  if not Assigned(FTrailer) then Exit;
  EncRef := FTrailer.Get('Encrypt');
  if not Assigned(EncRef) then Exit;  // not encrypted
  if EncRef is TPdfReferenceObject then
    FEncryptObjNum := TPdfReferenceObject(EncRef).ObjectNumber;
  EncObj := ResolveObject(EncRef);
  if not (EncObj is TPdfDictionaryObject) then Exit;
  Enc := TPdfDictionaryObject(EncObj);

  // Only the Standard security handler is supported.
  FiltObj := ResolveObject(Enc.Get('Filter'));
  if Assigned(FiltObj) and (FiltObj.AsName <> '') and not SameText(FiltObj.AsName, 'Standard') then
    raise EPdfPasswordRequired.Create('Unsupported PDF security handler: ' + FiltObj.AsName);

  V := Trunc(Enc.GetNumber('V', 0));
  R := Trunc(Enc.GetNumber('R', 0));
  if V >= 4 then LenBits := Trunc(Enc.GetNumber('Length', 128))
  else LenBits := Trunc(Enc.GetNumber('Length', 40));
  P := LongInt(Int64(Trunc(Enc.GetNumber('P', 0))));

  EncMeta := True;
  FiltObj := ResolveObject(Enc.Get('EncryptMetadata'));
  if Assigned(FiltObj) and (FiltObj.AsNumber = 0) and (FiltObj.Kind = pokBoolean) then EncMeta := False;

  // Crypt-filter methods (V>=4) or implicit RC4 (V<4).
  if V >= 4 then
  begin
    CF := nil;
    CFObj := ResolveObject(Enc.Get('CF'));
    if CFObj is TPdfDictionaryObject then CF := TPdfDictionaryObject(CFObj);
    StmName := Enc.GetName('StmF');
    StrName := Enc.GetName('StrF');
    Stm := MethodFor(CF, StmName);
    Str := MethodFor(CF, StrName);
  end
  else
  begin
    Stm := cmRC4;
    Str := cmRC4;
  end;

  FSecurity := TPdfSecurityHandler.Create;
  FSecurity.R := R;
  FSecurity.V := V;
  ok := FSecurity.Setup(R, V, LenBits,
          StrBytes(Enc, 'O'), StrBytes(Enc, 'U'),
          StrBytes(Enc, 'OE'), StrBytes(Enc, 'UE'),
          IDBytes, P, EncMeta, Stm, Str, FPassword);

  if not ok then
    raise EPdfPasswordRequired.Create('This PDF is password protected.');

  FEncryptReady := True;  // from now on, object strings/streams are decrypted
end;

procedure TPdfDocument.BuildPages;
var Root, Pages: TPdfObject;
begin
  Root := ResolveObject(FTrailer.Get('Root'));
  if Root is TPdfDictionaryObject then begin
    Pages := ResolveObject(TPdfDictionaryObject(Root).Get('Pages'));
    if Pages is TPdfDictionaryObject then WalkPageTree(TPdfDictionaryObject(Pages), nil);
  end;
end;
procedure TPdfDocument.WalkPageTree(PageDict: TPdfDictionaryObject; ParentResources: TPdfDictionaryObject);
var T: string;
  KidsObj, K: TPdfObject;
  Kids: TPdfArrayObject;
  I: Integer;
  R: TPdfDictionaryObject;
  Page: TPdfPage;
begin
  R := ParentResources;
  K := ResolveObject(PageDict.Get('Resources'));
  if K is TPdfDictionaryObject then R := TPdfDictionaryObject(K);
  T := PageDict.GetName('Type');
  if T='Page' then begin
    Page := TPdfPage.Create;
    Page.Resources := R;
    SetupPageBoxes(Page, Self, PageDict);
    Page.OwnerDoc := Self;
    Page.PageDict := PageDict;
    FPages.Add(Page);
  end  // content parsed lazily via Page.EnsureParsed
  else begin
    KidsObj := ResolveObject(PageDict.Get('Kids'));
    if KidsObj is TPdfArrayObject then begin
      Kids := TPdfArrayObject(KidsObj);
      for I := 0 to Kids.Items.Count-1 do begin
        K := ResolveObject(TPdfObject(Kids.Items[I]));
        if K is TPdfDictionaryObject then WalkPageTree(TPdfDictionaryObject(K), R);
      end;
    end;
  end;
end;
procedure TPdfDocument.ParsePageContent(Page: TPdfPage; PageDict, Resources: TPdfDictionaryObject);
var C, O: TPdfObject;
  Arr: TPdfArrayObject;
  I: Integer;
  NL: TPdfBytes;
begin
  // A page's /Contents may be an array of streams. Per the PDF spec these form
  // ONE logical stream — the graphics state (q/Q, colours) carries across the
  // boundaries — so concatenate them (separated by a newline so tokens at a
  // boundary don't merge) and interpret the whole thing in a single pass.
  C := ResolveObject(PageDict.Get('Contents'));
  if C is TPdfStreamObject then
    Page.RawContent := TPdfStreamObject(C).DecodedData
  else if C is TPdfArrayObject then
  begin
    SetLength(NL, 1);
    NL[0] := 10;
    Arr := TPdfArrayObject(C);
    for I := 0 to Arr.Items.Count-1 do
    begin
      O := ResolveObject(TPdfObject(Arr.Items[I]));
      if O is TPdfStreamObject then
      begin
        if Length(Page.RawContent) > 0 then Page.RawContent := Page.RawContent + NL;
        Page.RawContent := Page.RawContent + TPdfStreamObject(O).DecodedData;
      end;
    end;
  end;
  if Length(Page.RawContent) > 0 then
  begin
    FMarkCounter := 0;  // fresh marked-content ids for this page
    InterpretContent(Page, Page.RawContent, Resources, PdfIdentityMatrix);
  end;
  ParseAnnotations(Page, PageDict);
end;

procedure TPdfDocument.ParseAnnotations(Page: TPdfPage; PageDict: TPdfDictionaryObject);
var AnnotsObj, Ann, SubtypeObj, RectObj, AObj, SObj, UriObj: TPdfObject;
    Annots: TPdfArrayObject;
    AnnDict, ADict: TPdfDictionaryObject;
    I, N: Integer;
    R: TPdfRect;
    URL: string;
begin
  AnnotsObj := ResolveObject(PageDict.Get('Annots'));
  if not (AnnotsObj is TPdfArrayObject) then Exit;
  Annots := TPdfArrayObject(AnnotsObj);
  for I := 0 to Annots.Items.Count - 1 do
  begin
    Ann := ResolveObject(TPdfObject(Annots.Items[I]));
    if not (Ann is TPdfDictionaryObject) then Continue;
    AnnDict := TPdfDictionaryObject(Ann);
    SubtypeObj := ResolveObject(AnnDict.Get('Subtype'));
    if not Assigned(SubtypeObj) or not SameText(SubtypeObj.AsName, 'Link') then Continue;
    RectObj := ResolveObject(AnnDict.Get('Rect'));
    if not (RectObj is TPdfArrayObject) then Continue;
    R := RectFromArray(TPdfArrayObject(RectObj), Page.CropBox);
    // Extract the external URI target, if any: /A << /S /URI /URI (...) >>.
    URL := '';
    AObj := ResolveObject(AnnDict.Get('A'));
    if AObj is TPdfDictionaryObject then
    begin
      ADict := TPdfDictionaryObject(AObj);
      SObj := ResolveObject(ADict.Get('S'));
      if Assigned(SObj) and SameText(SObj.AsName, 'URI') then
      begin
        UriObj := ResolveObject(ADict.Get('URI'));
        if UriObj is TPdfStringObject then URL := string(TPdfStringObject(UriObj).Value);
      end;
    end;
    N := Length(Page.LinkRects);
    SetLength(Page.LinkRects, N + 1);
    SetLength(Page.LinkURLs,  N + 1);
    Page.LinkRects[N] := R;
    Page.LinkURLs[N]  := URL;
  end;
end;

type
  TOperand = class
    Obj: TPdfObject;
    constructor Create(AObj: TPdfObject);
    destructor Destroy;
    override;
  end;
constructor TOperand.Create(AObj: TPdfObject);
begin
  inherited Create;
  Obj := AObj;
end;
destructor TOperand.Destroy;
begin
  Obj.Free;
  inherited Destroy;
end;

destructor TPdfShadingElement.Destroy;
begin
  Func.Free;
  TintTransform.Free;
  inherited Destroy;
end;

destructor TPdfFunction.Destroy;
var I: Integer;
begin
  for I := 0 to High(SubFns) do SubFns[I].Free;
  PSProg.Free;
  inherited Destroy;
end;

function TPdfFunction.ReadSampleBits(BitOffset, NBits: Integer): Int64;
var I, BytePos, BitInByte: Integer;
begin
  Result := 0;
  for I := 0 to NBits-1 do
  begin
    BytePos := (BitOffset + I) div 8;
    BitInByte := 7 - ((BitOffset + I) mod 8);
    Result := Result shl 1;
    if (BytePos < Length(Samples)) then
      Result := Result or ((Samples[BytePos] shr BitInByte) and 1);
  end;
end;

procedure TPdfFunction.Eval(t: Double; out Outp: TDoubleArray);
var I, K, Bits, BytePos, BitOff, SampMax, Lo, Hi, J: Integer;
    tt, e, frac, sLo, sHi, dmin, dmax, emin, emax: Double;
    rawLo, rawHi: Int64;
begin
  Outp := nil;
  // Clamp input to the function domain.
  if Length(Domain) >= 2 then
  begin
    if t < Domain[0] then t := Domain[0];
    if t > Domain[1] then t := Domain[1];
  end;

  case FunctionType of
    2:
      begin
        SetLength(Outp, Length(C0));
        if NExp = 1 then tt := t
        else if t <= 0 then tt := 0
        else tt := Exp(NExp * Ln(t));
        for I := 0 to High(C0) do
          Outp[I] := C0[I] + tt * (C1[I] - C0[I]);
      end;
    3:
      begin
        K := 0;
        while (K < Length(Bounds3)) and (t >= Bounds3[K]) do Inc(K);
        // Subdomain [dmin,dmax] for subfunction K
        if K = 0 then dmin := Domain[0] else dmin := Bounds3[K-1];
        if K >= Length(Bounds3) then dmax := Domain[1] else dmax := Bounds3[K];
        if (K*2+1) < Length(Encode3) then begin
          emin := Encode3[K*2];
          emax := Encode3[K*2+1];
        end
        else begin
          emin := 0;
          emax := 1;
        end;
        if dmax = dmin then e := emin
        else e := emin + (t - dmin) * (emax - emin) / (dmax - dmin);
        if (K <= High(SubFns)) and Assigned(SubFns[K]) then SubFns[K].Eval(e, Outp)
        else SetLength(Outp, 0);
      end;
    0:
      begin
        SetLength(Outp, NOut);
        if (Length(Size0) < 1) or (Size0[0] < 1) then Exit;
        // Map t (1-D input) through Encode to sample coordinate.
        dmin := Domain[0];
        dmax := Domain[1];
        if (Length(Encode0) >= 2) then begin
          emin := Encode0[0];
          emax := Encode0[1];
        end
        else begin
          emin := 0;
          emax := Size0[0]-1;
        end;
        if dmax = dmin then e := emin
        else e := emin + (t - dmin) * (emax - emin) / (dmax - dmin);
        if e < 0 then e := 0;
        if e > Size0[0]-1 then e := Size0[0]-1;
        Lo := Trunc(e);
        Hi := Lo + 1;
        if Hi > Size0[0]-1 then Hi := Size0[0]-1;
        frac := e - Lo;
        Bits := BitsPerSample;
        SampMax := (1 shl Bits) - 1;
        if SampMax = 0 then SampMax := 1;
        for I := 0 to NOut-1 do
        begin
          // sample value at index Lo and Hi for output component I
          rawLo := ReadSampleBits((Lo*NOut + I)*Bits, Bits);
          rawHi := ReadSampleBits((Hi*NOut + I)*Bits, Bits);
          sLo := rawLo / SampMax;
          sHi := rawHi / SampMax;
          e := sLo + frac * (sHi - sLo);
          if Length(Decode0) >= (I*2+2) then begin
            dmin := Decode0[I*2];
            dmax := Decode0[I*2+1];
          end
          else if Length(RangeArr) >= (I*2+2) then begin
            dmin := RangeArr[I*2];
            dmax := RangeArr[I*2+1];
          end
          else begin
            dmin := 0;
            dmax := 1;
          end;
          Outp[I] := dmin + e * (dmax - dmin);
        end;
      end;
  else
    SetLength(Outp, 0);
  end;
end;

// Multi-input evaluation. Type 4 runs the PostScript program over all inputs;
// other types fall back to the single-input Eval using the first input.
procedure TPdfFunction.EvalN(const Inp: TDoubleArray; out Outp: TDoubleArray);
var Stk: TList;
  I, NOutW: Integer;
  pd: PPSNum;
  t: Double;
begin
  Outp := nil;
  if (FunctionType = 4) and Assigned(PSProg) then
  begin
    Stk := TList.Create;
    try
      for I := 0 to High(Inp) do
      begin
        // clamp each input to its domain pair if present
        t := Inp[I];
        if Length(Domain) >= (I*2+2) then
        begin
          if t < Domain[I*2]   then t := Domain[I*2];
          if t > Domain[I*2+1] then t := Domain[I*2+1];
        end;
        New(pd);
        pd^ := t;
        Stk.Add(pd);
      end;
      PSExec(TPSNode(PSProg), Stk);
      // The program leaves NOut results on the stack (bottom..top = out[0..n-1]).
      if Length(RangeArr) >= 2 then NOutW := Length(RangeArr) div 2
      else NOutW := Stk.Count;
      if NOutW > Stk.Count then NOutW := Stk.Count;
      SetLength(Outp, NOutW);
      for I := 0 to NOutW-1 do
      begin
        pd := PPSNum(Stk[Stk.Count - NOutW + I]);
        t := pd^;
        // clamp to Range
        if Length(RangeArr) >= (I*2+2) then
        begin
          if t < RangeArr[I*2]   then t := RangeArr[I*2];
          if t > RangeArr[I*2+1] then t := RangeArr[I*2+1];
        end;
        Outp[I] := t;
      end;
    finally
      for I := 0 to Stk.Count-1 do Dispose(PPSNum(Stk[I]));
      Stk.Free;
    end;
  end
  else if Length(Inp) > 0 then
    Eval(Inp[0], Outp)
  else
    Eval(0, Outp);
end;

// Build a PDF function object from a dict/stream/array of functions.
function TPdfDocument.BuildFunction(Obj: TPdfObject): TPdfFunction;
var D: TPdfDictionaryObject;
  A, FA: TPdfArrayObject;
  I: Integer;
  O: TPdfObject;
    PSBody: AnsiString;
    PSP: Integer;
  procedure LoadNums(Src: TPdfObject; out Arr: TDoubleArray);
  var Ar: TPdfArrayObject;
    J: Integer;
  begin
    Arr := nil;
    Src := ResolveObject(Src);
    if Src is TPdfArrayObject then
    begin
      Ar := TPdfArrayObject(Src);
      SetLength(Arr, Ar.Items.Count);
      for J := 0 to Ar.Items.Count-1 do Arr[J] := ResolveObject(TPdfObject(Ar.Items[J])).AsNumber;
    end;
  end;
begin
  Result := nil;
  Obj := ResolveObject(Obj);
  // An array of functions: wrap as a synthetic stitching-like container is not
  // needed here — shadings reference a single function, so take the first.
  if Obj is TPdfArrayObject then
  begin
    if TPdfArrayObject(Obj).Items.Count > 0 then
      Result := BuildFunction(TPdfObject(TPdfArrayObject(Obj).Items[0]));
    Exit;
  end;
  if not (Obj is TPdfDictionaryObject) then Exit;
  D := TPdfDictionaryObject(Obj);
  Result := TPdfFunction.Create;
  Result.FunctionType := Trunc(D.GetNumber('FunctionType', -1));
  LoadNums(D.Get('Domain'), Result.Domain);
  case Result.FunctionType of
    2:
      begin
        LoadNums(D.Get('C0'), Result.C0);
        LoadNums(D.Get('C1'), Result.C1);
        if Length(Result.C0) = 0 then begin
          SetLength(Result.C0,1);
          Result.C0[0]:=0;
        end;
        if Length(Result.C1) = 0 then begin
          SetLength(Result.C1,1);
          Result.C1[0]:=1;
        end;
        Result.NExp := D.GetNumber('N', 1);
      end;
    3:
      begin
        LoadNums(D.Get('Bounds'), Result.Bounds3);
        LoadNums(D.Get('Encode'), Result.Encode3);
        O := ResolveObject(D.Get('Functions'));
        if O is TPdfArrayObject then
        begin
          FA := TPdfArrayObject(O);
          SetLength(Result.SubFns, FA.Items.Count);
          for I := 0 to FA.Items.Count-1 do
            Result.SubFns[I] := BuildFunction(TPdfObject(FA.Items[I]));
        end;
      end;
    0:
      begin
        LoadNums(D.Get('Range'), Result.RangeArr);
        LoadNums(D.Get('Encode'), Result.Encode0);
        LoadNums(D.Get('Decode'), Result.Decode0);
        Result.BitsPerSample := Trunc(D.GetNumber('BitsPerSample', 8));
        O := ResolveObject(D.Get('Size'));
        if O is TPdfArrayObject then
        begin
          A := TPdfArrayObject(O);
          SetLength(Result.Size0, A.Items.Count);
          for I := 0 to A.Items.Count-1 do Result.Size0[I] := Trunc(TPdfObject(A.Items[I]).AsNumber);
        end;
        Result.NIn := 1;
        if Length(Result.RangeArr) > 0 then Result.NOut := Length(Result.RangeArr) div 2 else Result.NOut := 1;
        if D is TPdfStreamObject then Result.Samples := TPdfStreamObject(D).DecodedData;
      end;
    4:
      begin
        // PostScript calculator: parse the program text from the stream body.
        LoadNums(D.Get('Range'), Result.RangeArr);
        if D is TPdfStreamObject then
        begin
          PSBody := BytesToAnsi(TPdfStreamObject(D).DecodedData);
          PSP := 1;
          // skip leading whitespace up to the opening '{'
          while (PSP <= Length(PSBody)) and (PSBody[PSP] <> '{') do Inc(PSP);
          if PSP <= Length(PSBody) then begin
            Inc(PSP);
            Result.PSProg := PSParseProc(PSBody, PSP);
          end;
        end;
      end;
  end;
end;

// Build a shading paint element from a shading dictionary, capturing the CTM.
function TPdfDocument.BuildShading(ShadingObj: TPdfObject; const ACTM: TPdfMatrix): TPdfShadingElement;
var D: TPdfDictionaryObject;
  O, TintObj: TPdfObject;
  A: TPdfArrayObject;
  I, ST: Integer;
    CSName: string;
begin
  Result := nil;
  TintObj := nil;
  ShadingObj := ResolveObject(ShadingObj);
  if not (ShadingObj is TPdfDictionaryObject) then Exit;
  D := TPdfDictionaryObject(ShadingObj);
  ST := Trunc(D.GetNumber('ShadingType', 0));
  if (ST <> 2) and (ST <> 3) then Exit;  // only axial/radial supported
  // Device colour spaces convert directly; Separation/DeviceN convert through
  // their tint transform (built below). Indexed/Pattern/Lab are skipped.
  O := ResolveObject(D.Get('ColorSpace'));
  if O is TPdfNameObject then
  begin
    if not (SameText(O.AsName,'DeviceRGB') or SameText(O.AsName,'DeviceGray') or
            SameText(O.AsName,'DeviceCMYK') or SameText(O.AsName,'CalRGB') or
            SameText(O.AsName,'CalGray')) then Exit;
  end
  else if O is TPdfArrayObject then
  begin
    A := TPdfArrayObject(O);
    if A.Items.Count < 1 then Exit;
    CSName := ResolveObject(TPdfObject(A.Items[0])).AsName;
    if SameText(CSName, 'ICCBased') then
      // device-like; handled by output component count
    else if (SameText(CSName,'Separation') or SameText(CSName,'DeviceN')) and
            (A.Items.Count >= 4) then
      TintObj := TPdfObject(A.Items[3])   // tint transform: tints -> alternate space
    else
      Exit;  // Indexed / Pattern / Lab not supported
  end;
  Result := TPdfShadingElement.Create;
  Result.Kind := pekPath;
  Result.ShadingType := ST;
  Result.CTM := ACTM;
  if Assigned(TintObj) then Result.TintTransform := BuildFunction(TintObj);
  O := ResolveObject(D.Get('Coords'));
  if O is TPdfArrayObject then
  begin
    A := TPdfArrayObject(O);
    SetLength(Result.Coords, A.Items.Count);
    for I := 0 to A.Items.Count-1 do Result.Coords[I] := ResolveObject(TPdfObject(A.Items[I])).AsNumber;
  end;
  Result.Domain[0] := 0;
  Result.Domain[1] := 1;
  O := ResolveObject(D.Get('Domain'));
  if (O is TPdfArrayObject) and (TPdfArrayObject(O).Items.Count >= 2) then
  begin
    Result.Domain[0] := TPdfObject(TPdfArrayObject(O).Items[0]).AsNumber;
    Result.Domain[1] := TPdfObject(TPdfArrayObject(O).Items[1]).AsNumber;
  end;
  Result.ExtendStart := False;
  Result.ExtendEnd := False;
  O := ResolveObject(D.Get('Extend'));
  if (O is TPdfArrayObject) and (TPdfArrayObject(O).Items.Count >= 2) then
  begin
    Result.ExtendStart := TPdfObject(TPdfArrayObject(O).Items[0]).AsNumber <> 0;
    Result.ExtendEnd   := TPdfObject(TPdfArrayObject(O).Items[1]).AsNumber <> 0;
  end;
  Result.Func := BuildFunction(D.Get('Function'));
  if not Assigned(Result.Func) then begin
    Result.Free;
    Result := nil;
  end;
end;

// Extract an ExtGState soft mask (the grayscale shape image inside its /G group)
// into a TPdfSoftMask. Always returns a non-nil mask; Valid is False if no image
// was found (the masked element is then hidden rather than drawn unmasked).
function TPdfDocument.BuildSoftMask(Page: TPdfPage; SMaskDict: TPdfDictionaryObject; const ACTM: TPdfMatrix): TPdfSoftMask;
var G, GMatrix, GRes: TPdfObject;
  FormCTM: TPdfMatrix;
  TmpPage: TPdfPage;
    I: Integer;
    GResD: TPdfDictionaryObject;
    Arr: TPdfArrayObject;
begin
  Result := TPdfSoftMask.Create;
  Result.Valid := False;
  G := ResolveObject(SMaskDict.Get('G'));
  if not (G is TPdfStreamObject) then Exit;

  FormCTM := ACTM;
  GMatrix := ResolveObject(TPdfStreamObject(G).Get('Matrix'));
  if (GMatrix is TPdfArrayObject) and (TPdfArrayObject(GMatrix).Items.Count >= 6) then
  begin
    Arr := TPdfArrayObject(GMatrix);
    FormCTM := PdfMatrixMultiply(PdfMatrixFrom(
      TPdfObject(Arr.Items[0]).AsNumber, TPdfObject(Arr.Items[1]).AsNumber,
      TPdfObject(Arr.Items[2]).AsNumber, TPdfObject(Arr.Items[3]).AsNumber,
      TPdfObject(Arr.Items[4]).AsNumber, TPdfObject(Arr.Items[5]).AsNumber), FormCTM);
  end;
  GRes := ResolveObject(TPdfStreamObject(G).Get('Resources'));
  if GRes is TPdfDictionaryObject then GResD := TPdfDictionaryObject(GRes) else GResD := nil;

  TmpPage := TPdfPage.Create;
  try
    FBuildingMask := True;
    try
      InterpretContent(TmpPage, TPdfStreamObject(G).DecodedData, GResD, FormCTM);
    finally
      FBuildingMask := False;
    end;
    // Take the first image element as the mask shape; detach it (we own it).
    for I := 0 to TmpPage.Elements.Count - 1 do
      if TObject(TmpPage.Elements[I]) is TPdfImageElement then
      begin
        Result.MaskImage := TPdfImageElement(TmpPage.Elements[I]);
        Result.Matrix := TPdfImageElement(TmpPage.Elements[I]).Matrix;
        Result.Valid := True;
        TmpPage.Elements.OwnsObjects := False;
        TmpPage.Elements.Delete(I);
        TmpPage.Elements.OwnsObjects := True;
        Break;
      end;
  finally
    TmpPage.Free;
  end;
end;

// Decode an [/Indexed base hival lookup] colour space into an expanded RGB
// palette (3 bytes per entry). Returns the entry count (hival+1), 0 on failure.
function TPdfDocument.BuildIndexedRGBPalette(CSArr: TPdfArrayObject; out Pal: TPdfBytes): Integer;
var BaseObj, HiObj, LookObj, ICCStm: TPdfObject;
  HiVal, NComps, I, Idx: Integer;
    Lookup: TPdfBytes;
    BaseKind: string;
    LS: AnsiString;
    c, m, y, k: Integer;
    rr, gg, bb: Integer;
begin
  Result := 0;
  Pal := nil;
  if CSArr.Items.Count < 4 then Exit;
  BaseObj := ResolveObject(TPdfObject(CSArr.Items[1]));
  HiObj   := ResolveObject(TPdfObject(CSArr.Items[2]));
  LookObj := ResolveObject(TPdfObject(CSArr.Items[3]));
  if not Assigned(HiObj) then Exit;
  HiVal := Trunc(HiObj.AsNumber);
  if HiVal < 0 then Exit;

  // Determine base colour space component layout.
  BaseKind := 'RGB';
  NComps := 3;
  if Assigned(BaseObj) then
  begin
    if BaseObj.Kind = pokName then
    begin
      if SameText(BaseObj.AsName,'DeviceGray') or SameText(BaseObj.AsName,'CalGray') or SameText(BaseObj.AsName,'G') then begin
        BaseKind:='GRAY';
        NComps:=1;
      end
      else if SameText(BaseObj.AsName,'DeviceCMYK') or SameText(BaseObj.AsName,'CMYK') then begin
        BaseKind:='CMYK';
        NComps:=4;
      end
      else begin
        BaseKind:='RGB';
        NComps:=3;
      end;
    end
    else if BaseObj is TPdfArrayObject then
    begin
      if (TPdfArrayObject(BaseObj).Items.Count >= 2) and
         SameText(TPdfObject(TPdfArrayObject(BaseObj).Items[0]).AsName, 'ICCBased') then
      begin
        ICCStm := ResolveObject(TPdfObject(TPdfArrayObject(BaseObj).Items[1]));
        if ICCStm is TPdfStreamObject then
        begin
          NComps := Trunc(TPdfStreamObject(ICCStm).GetNumber('N', 3));
          if NComps = 1 then BaseKind := 'GRAY'
          else if NComps = 4 then BaseKind := 'CMYK'
          else begin
            BaseKind := 'RGB';
            NComps := 3;
          end;
        end;
      end;
    end;
  end;

  // Gather the lookup bytes (a string or a stream).
  Lookup := nil;
  if LookObj is TPdfStreamObject then
    Lookup := TPdfStreamObject(LookObj).DecodedData
  else if LookObj is TPdfStringObject then
  begin
    LS := TPdfStringObject(LookObj).Value;
    SetLength(Lookup, Length(LS));
    for I := 1 to Length(LS) do Lookup[I-1] := Byte(LS[I]);
  end;
  if Length(Lookup) < (HiVal+1) * NComps then Exit;

  SetLength(Pal, (HiVal+1) * 3);
  for Idx := 0 to HiVal do
  begin
    if BaseKind = 'GRAY' then
    begin
      rr := Lookup[Idx];
      gg := rr;
      bb := rr;
    end
    else if BaseKind = 'CMYK' then
    begin
      c := Lookup[Idx*4+0];
      m := Lookup[Idx*4+1];
      y := Lookup[Idx*4+2];
      k := Lookup[Idx*4+3];
      rr := (255 - c) * (255 - k) div 255;
      gg := (255 - m) * (255 - k) div 255;
      bb := (255 - y) * (255 - k) div 255;
    end
    else
    begin
      rr := Lookup[Idx*3+0];
      gg := Lookup[Idx*3+1];
      bb := Lookup[Idx*3+2];
    end;
    Pal[Idx*3+0] := Byte(rr);
    Pal[Idx*3+1] := Byte(gg);
    Pal[Idx*3+2] := Byte(bb);
  end;
  Result := HiVal + 1;
end;

procedure TPdfDocument.InterpretContent(Page: TPdfPage; const Bytes: TPdfBytes; Resources: TPdfDictionaryObject; const InitialCTM: TPdfMatrix; InitialSoftMask: TObject = nil; InitialMark: Integer = -1);
var S: AnsiString;
  P: Integer;
  Stack: TObjectList;
  GS: TPdfGraphicsStack;
  Fonts: TFPHashObjectList;
  // Marked-content nesting: a stack of BDC/BMC block ids (innermost last). CurMark
  // is the id attached to every element created while the block is open, so all
  // vectors of one logical figure share it. Modified only in the main loop (not a
  // nested proc), so a proc-scope dynamic array is safe re: the FPC nested-proc bug.
  MarkStack: array of Integer;
  // =- Vector path construction state (current point in user space) =-=-=-=-=-
  // PathSubs/PathCur are object fields (see class declaration) to avoid an FPC
  // nested-procedure dynamic-array corruption bug. SavedSubs/SavedCur preserve
  // the caller's path across nested (form/mask) interpretation.
  SavedSubs: array of TPdfSubPath;
  SavedFlat: array of TPdfPathPoint;
  SavedCur: array of TPdfPathPoint;
  PathHasCur: Boolean;  // a subpath is currently open
  UserX, UserY, StartUserX, StartUserY: Double;  // current/start point in user space
  PendingClip: Boolean;  // a W/W* clip awaits the next painting operator
  PClipX1, PClipY1, PClipX2, PClipY2: Double;  // page-space bbox of the pending clip
  // Pending non-rectangular clip path geometry, snapshotted at the W/W* operator.
  PendingClipPts: array of TPdfPathPoint;
  PendingClipSubs: array of TPdfSubPath;
  PendingClipEO, PendingClipHasPath: Boolean;
  InheritedMask: TObject;  // soft mask a form was invoked under (kept throughout)
  // Id of the marked-content block currently open (innermost), or the inherited
  // mark if none is open in this (possibly form-recursed) stream.
  function CurMark: Integer;
  begin
    if Length(MarkStack) > 0 then Result := MarkStack[High(MarkStack)]
    else Result := InitialMark;
  end;
  // Copy the active clip rectangle and soft mask onto a freshly created element.
  procedure SetElemClip(E: TPdfPageElement);
  begin
    if GS.Current.HasClip then
    begin
      E.HasClip := True;
      E.Clip.X1 := GS.Current.ClipX1;
      E.Clip.Y1 := GS.Current.ClipY1;
      E.Clip.X2 := GS.Current.ClipX2;
      E.Clip.Y2 := GS.Current.ClipY2;
    end;
    E.SoftMask := GS.Current.SoftMask;
    E.ClipPaths := Copy(GS.Current.ClipPaths);  // refs to page-owned TPdfClipPath
    E.Mark := CurMark;
  end;
  function NextToken: string;
  var St, D: Integer;
  begin
    while (P <= Length(S)) and (S[P] <= ' ') do Inc(P);
    if P > Length(S) then Exit('');
    if S[P]='%' then begin
      while (P <= Length(S)) and not (S[P] in [#10,#13]) do Inc(P);
      Exit(NextToken);
    end;
    // Skip stray '>' (e.g. left over after a malformed hex string) and PostScript
    // braces. A lone delimiter the general reader can't advance past would return
    // an empty token, which the main loop treats as end-of-stream — aborting the
    // rest of the page. Skipping them keeps parsing robust.
    if S[P] in ['>', '{', '}'] then begin
      Inc(P);
      Exit(NextToken);
    end;
    // Literal string with nested-paren support
    if S[P]='(' then begin
      St := P;
      Inc(P);
      D := 1;
      while (P <= Length(S)) and (D > 0) do begin
        if S[P]='\' then Inc(P)
        else if S[P]='(' then Inc(D)
        else if S[P]=')' then Dec(D);
        Inc(P);
      end;
      Exit(Copy(S, St, P - St));
    end;
    // << dict >> — consume the entire block so that >> never appears as a bare token
    // that would be mistaken for end-of-data by the general token reader.
    if S[P]='<' then begin
      if (P < Length(S)) and (S[P+1]='<') then begin
        St := P;
        Inc(P, 2);
        D := 1;
        while (P < Length(S)) and (D > 0) do begin
          if (S[P]='<') and (P+1 < Length(S)) and (S[P+1]='<') then begin
            Inc(D);
            Inc(P, 2);
          end
          else if (S[P]='>') and (P+1 < Length(S)) and (S[P+1]='>') then begin
            Dec(D);
            Inc(P, 2);
          end
          // A nested HEX string <...> must be skipped as a unit, otherwise its
          // closing '>' pairs with the dict's first '>' as a false '>>' — e.g.
          // `<</ActualText<FEFF0009>>>` would stop one '>' early and leave a stray
          // '>' that yields an empty token and aborts the whole content stream.
          else if S[P]='<' then begin
            Inc(P);
            while (P <= Length(S)) and (S[P] <> '>') do Inc(P);
            if P <= Length(S) then Inc(P);
          end
          // Nested literal string (...) may itself contain < > ( ) — skip as a unit.
          else if S[P]='(' then begin
            Inc(P);
            while (P <= Length(S)) and (S[P] <> ')') do begin
              if S[P]='\' then Inc(P);
              Inc(P);
            end;
            if P <= Length(S) then Inc(P);
          end
          else Inc(P);
        end;
        // If we hit end-of-string while still inside, P stopped at len; include it.
        Exit(Copy(S, St, P - St));
      end;
      // Hex string: <HHHH>
      St := P;
      Inc(P);
      while (P <= Length(S)) and (S[P] <> '>') do Inc(P);
      if P <= Length(S) then Inc(P);
      Exit(Copy(S, St, P - St));
    end;
    // Array delimiters are single-char tokens
    if S[P] in ['[', ']'] then begin
      St := P;
      Inc(P);
      Exit(Copy(S, St, 1));
    end;
    // Name
    if S[P]='/' then begin
      St := P;
      Inc(P);
      while (P <= Length(S)) and not (S[P] <= ' ') and not (S[P] in ['[',']','<','>','(',')','/']) do Inc(P);
      Exit(Copy(S, St, P - St));
    end;
    // General token — stop at whitespace or PDF delimiters
    St := P;
    while (P <= Length(S)) and not (S[P] <= ' ') and not (S[P] in ['[',']','<','>','(',')','/']) do Inc(P);
    Result := Copy(S, St, P - St);
  end;
  function HexStrToAnsi(const H: string): AnsiString;
  var I, N1, N2: Integer;
  begin
    Result := '';
    I := 2;  // skip '<'
    while I < Length(H) do begin  // Length(H) is the index of '>'
      if H[I] <= ' ' then begin
        Inc(I);
        Continue;
      end;
      if I >= Length(H) then Break;
      N1 := 0;
      if H[I] in ['0'..'9'] then N1 := Ord(H[I]) - Ord('0')
      else if H[I] in ['A'..'F'] then N1 := Ord(H[I]) - Ord('A') + 10
      else if H[I] in ['a'..'f'] then N1 := Ord(H[I]) - Ord('a') + 10;
      Inc(I);
      if I >= Length(H) then begin
        Result := Result + AnsiChar(N1 shl 4);
        Break;
      end;
      N2 := 0;
      if H[I] in ['0'..'9'] then N2 := Ord(H[I]) - Ord('0')
      else if H[I] in ['A'..'F'] then N2 := Ord(H[I]) - Ord('A') + 10
      else if H[I] in ['a'..'f'] then N2 := Ord(H[I]) - Ord('a') + 10;
      Inc(I);
      Result := Result + AnsiChar((N1 shl 4) or N2);
    end;
  end;
  function PopObj: TPdfObject;
  var Op: TOperand;
  begin
    if Stack.Count=0 then Exit(nil);
    Op := TOperand(Stack.Last);
    Result := Op.Obj;
    Op.Obj := nil;
    Stack.OwnsObjects := False;
    Stack.Delete(Stack.Count-1);
    Stack.OwnsObjects := True;
    Op.Free;
  end;
  procedure PushObj(O: TPdfObject);
  begin
    Stack.Add(TOperand.Create(O));
  end;
  procedure Clear;
  begin
    Stack.Clear;
  end;
  function ObjStr(O: TPdfObject): AnsiString;
  begin
    if Assigned(O) then Result := O.AsString else Result := '';
  end;
  // Unescape PDF literal string backslash sequences; T is the full token including outer '(' ')'.
  function UnescapeLitStr(const T: string): AnsiString;
  var I: Integer;
    V: Byte;
  begin
    Result := '';
    I := 2;  // skip opening '('
    while I < Length(T) do // stop before closing ')'
    begin
      if T[I] = '\' then
      begin
        Inc(I);
        if I >= Length(T) then Break;
        case T[I] of
          'n': Result := Result + #10;
          'r': Result := Result + #13;
          't': Result := Result + #9;
          'b': Result := Result + #8;
          'f': Result := Result + #12;
          '\': Result := Result + '\';
          '(': Result := Result + '(';
          ')': Result := Result + ')';
          '0'..'7': begin
            V := Ord(T[I]) - Ord('0');
            if (I+1 < Length(T)) and (T[I+1] in ['0'..'7']) then begin
              Inc(I);
              V := V*8 + (Ord(T[I])-Ord('0'));
            end;
            if (I+1 < Length(T)) and (T[I+1] in ['0'..'7']) then begin
              Inc(I);
              V := V*8 + (Ord(T[I])-Ord('0'));
            end;
            Result := Result + AnsiChar(V);
          end;
        else
          Result := Result + AnsiChar(T[I]);
        end;
      end
      else
        Result := Result + AnsiChar(T[I]);
      Inc(I);
    end;
  end;
  procedure ShowText(const Raw: AnsiString);
  var E: TPdfTextElement;
    F: TPdfFont;
    I: Integer;
    Adv, CA, ScaleA: Double;
      RawLen, TextLen, CID: Integer;
  begin
    E := TPdfTextElement.Create;
    E.FontName := GS.Current.FontName;
    E.FontSize := GS.Current.FontSize;
    E.Matrix   := PdfMatrixMultiply(GS.Current.TextMatrix, GS.Current.CTM);
    E.FillR    := GS.Current.FillR;
    E.FillG    := GS.Current.FillG;
    E.FillB    := GS.Current.FillB;
    E.RenderMode := GS.Current.TextRenderMode;
    E.StrokeR  := GS.Current.StrokeR;
    E.StrokeG  := GS.Current.StrokeG;
    E.StrokeB  := GS.Current.StrokeB;
    E.StrokeWidth := GS.Current.LineWidth *
      Sqrt(Abs(GS.Current.CTM.A*GS.Current.CTM.D - GS.Current.CTM.B*GS.Current.CTM.C));
    F := TPdfFont(Fonts.Find(GS.Current.FontName));
    if Assigned(F) then begin
      E.Text       := F.DecodeString(Raw);
      E.BaseFont   := F.BaseFont;
      E.FontProgram := F.FontProgram;
    end else
      E.Text := UnicodeString(Raw);
    SetElemClip(E);
    E.SoftMask := nil;  // text is the readable content — never hide it behind a mask
    Page.Elements.Add(E);

    RawLen  := Length(Raw);
    TextLen := Length(E.Text);
    ScaleA  := Abs(E.Matrix.A);  // text-space → page-space horizontal scale
    SetLength(E.CharWidths, TextLen);

    Adv := 0;
    if Assigned(F) and F.IsCIDFont then
    begin
      // Type0/CID font: codes are 2 bytes (Identity-H). Look up each CID's width
      // in the descendant /W array. Iterating per byte (the generic multi-byte
      // path) double-counts and uses the default width, marching text off the
      // line. Word spacing (Tw) applies only to single-byte code 32, so skip it.
      I := 1;
      while I <= RawLen do
      begin
        if I < RawLen then CID := (Byte(Raw[I]) shl 8) or Byte(Raw[I+1]) else CID := Byte(Raw[I]);
        CA := F.WidthOfCode(CID) / 1000.0 * GS.Current.FontSize
              * (GS.Current.HorizontalScaling / 100.0);
        CA := CA + GS.Current.CharSpacing;
        Adv := Adv + CA;
        Inc(I, 2);
      end;
      if TextLen > 0 then
        for I := 0 to TextLen - 1 do
          E.CharWidths[I] := (Adv * ScaleA) / TextLen;
    end
    else if (TextLen > 0) and (RawLen = TextLen) then
    begin
      // 1-byte encoding: each raw byte maps to exactly one Unicode character.
      // Store precise per-character page-space advance widths.
      for I := 1 to RawLen do
      begin
        if Assigned(F) then
          CA := F.WidthOfCode(Ord(Raw[I])) / 1000.0 * GS.Current.FontSize
                * (GS.Current.HorizontalScaling / 100.0)
        else
          CA := 0.6 * GS.Current.FontSize * (GS.Current.HorizontalScaling / 100.0);
        CA := CA + GS.Current.CharSpacing;
        if Ord(Raw[I]) = 32 then CA := CA + GS.Current.WordSpacing;
        E.CharWidths[I - 1] := CA * ScaleA;
        Adv := Adv + CA;
      end;
    end
    else
    begin
      // Multi-byte encoding or length mismatch: compute total advance first,
      // then distribute it proportionally across the decoded Unicode characters.
      for I := 1 to RawLen do
      begin
        if Assigned(F) then
          CA := F.WidthOfCode(Ord(Raw[I])) / 1000.0 * GS.Current.FontSize
                * (GS.Current.HorizontalScaling / 100.0)
        else
          CA := 0.6 * GS.Current.FontSize * (GS.Current.HorizontalScaling / 100.0);
        CA := CA + GS.Current.CharSpacing;
        if Ord(Raw[I]) = 32 then CA := CA + GS.Current.WordSpacing;
        Adv := Adv + CA;
      end;
      if TextLen > 0 then
        for I := 0 to TextLen - 1 do
          E.CharWidths[I] := (Adv * ScaleA) / TextLen;
    end;

    // Element bounding box.
    E.Bounds.X1 := E.Matrix.E;
    E.Bounds.X2 := E.Matrix.E + Adv * ScaleA;
    E.Bounds.Y1 := E.Matrix.F - E.FontSize * Abs(E.Matrix.D) * 0.2;
    E.Bounds.Y2 := E.Matrix.F + E.FontSize * Abs(E.Matrix.D);
    // True advance length along the (possibly rotated) baseline, in page space.
    E.AdvanceLen := Adv * Sqrt(E.Matrix.A*E.Matrix.A + E.Matrix.B*E.Matrix.B);
    if Adv <> 0 then
      GS.Current.TextMatrix :=
        PdfMatrixMultiply(PdfMatrixTranslate(Adv, 0), GS.Current.TextMatrix);
  end;
  procedure InlineImage;
  var E: TPdfImageElement;
    Start, Finish: Integer;
  begin
    Start := P;
    Finish := PosEx('EI', string(S), Start);
    if Finish = 0 then Finish := Length(S)+1;
    E := TPdfImageElement.Create(pekInlineImage);
    E.Data := SliceBytes(Bytes, Start-1, Finish-Start);
    E.Matrix := GS.Current.CTM;
    SetElemClip(E);
    Page.Elements.Add(E);
    P := Finish + 2;
    Clear;
  end;

  // =- Vector path helpers =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
  // Map a user-space point through the CTM into page space.
  procedure UserToPage(ux, uy: Double; out px, py: Double);
  begin
    px := GS.Current.CTM.A * ux + GS.Current.CTM.C * uy + GS.Current.CTM.E;
    py := GS.Current.CTM.B * ux + GS.Current.CTM.D * uy + GS.Current.CTM.F;
  end;
  // Append a page-space point to the in-progress subpath.
  procedure PathAddPage(px, py: Double);
  var N: Integer;
  begin
    N := Length(PathCur);
    SetLength(PathCur, N+1);
    PathCur[N].X := px;
    PathCur[N].Y := py;
  end;
  // Push the in-progress subpath (if any) into the completed list as a range
  // appended to the flat point buffer.
  procedure PathFlushSub(AClosed: Boolean);
  var N, M, I, Base: Integer;
  begin
    if Length(PathCur) = 0 then begin
      PathHasCur := False;
      Exit;
    end;
    Base := Length(FlatPts);
    M := Length(PathCur);
    SetLength(FlatPts, Base + M);
    for I := 0 to M-1 do FlatPts[Base+I] := PathCur[I];
    N := Length(PathSubs);
    SetLength(PathSubs, N+1);
    PathSubs[N].StartIdx := Base;
    PathSubs[N].Count := M;
    PathSubs[N].Closed := AClosed;
    SetLength(PathCur, 0);
    PathHasCur := False;
  end;
  procedure PathMoveTo(ux, uy: Double);
  var px, py: Double;
  begin
    PathFlushSub(False);
    UserX := ux;
    UserY := uy;
    StartUserX := ux;
    StartUserY := uy;
    UserToPage(ux, uy, px, py);
    PathAddPage(px, py);
    PathHasCur := True;
  end;
  procedure PathLineTo(ux, uy: Double);
  var px, py: Double;
  begin
    if not PathHasCur then begin
      PathMoveTo(ux, uy);
      Exit;
    end;
    UserX := ux;
    UserY := uy;
    UserToPage(ux, uy, px, py);
    PathAddPage(px, py);
  end;
  // Flatten a cubic Bézier (user-space control points) into line segments.
  procedure PathCurveTo(x1,y1,x2,y2,x3,y3: Double);
  const Steps = 16;
  var I: Integer;
    t, mt, bx, by, px, py, x0, y0: Double;
  begin
    x0 := UserX;
    y0 := UserY;
    for I := 1 to Steps do
    begin
      t := I / Steps;
      mt := 1 - t;
      bx := mt*mt*mt*x0 + 3*mt*mt*t*x1 + 3*mt*t*t*x2 + t*t*t*x3;
      by := mt*mt*mt*y0 + 3*mt*mt*t*y1 + 3*mt*t*t*y2 + t*t*t*y3;
      UserToPage(bx, by, px, py);
      PathAddPage(px, py);
    end;
    UserX := x3;
    UserY := y3;
  end;
  procedure PathRect(ux, uy, uw, uh: Double);
  var px, py, ax,ay: Double;
  begin
    // Rectangle as its own closed subpath: append 4 corners to PathCur, flush.
    PathFlushSub(False);
    UserToPage(ux,    uy,    px, py);
    PathAddPage(px, py);
    UserToPage(ux+uw, uy,    ax, ay);
    PathAddPage(ax, ay);
    UserToPage(ux+uw, uy+uh, ax, ay);
    PathAddPage(ax, ay);
    UserToPage(ux,    uy+uh, ax, ay);
    PathAddPage(ax, ay);
    PathFlushSub(True);
    UserX := ux;
    UserY := uy;
    StartUserX := ux;
    StartUserY := uy;
  end;
  procedure PathClose;
  begin
    if PathHasCur and (Length(PathCur) > 0) then PathFlushSub(True);
    UserX := StartUserX;
    UserY := StartUserY;
  end;
  procedure PathReset;
  begin
    SetLength(PathSubs, 0);
    SetLength(FlatPts, 0);
    SetLength(PathCur, 0);
    PathHasCur := False;
  end;
  // Bounding box (page space) of the path currently being built.
  function CurPathBBox(out x1,y1,x2,y2: Double): Boolean;
  var J: Integer;
    First: Boolean;
    procedure Acc(px,py: Double);
    begin
      if First then begin
        x1:=px;
        x2:=px;
        y1:=py;
        y2:=py;
        First:=False;
      end
      else begin
        if px<x1 then x1:=px;
        if px>x2 then x2:=px;
        if py<y1 then y1:=py;
        if py>y2 then y2:=py;
      end;
    end;
  begin
    First := True;
    x1:=0;
    y1:=0;
    x2:=0;
    y2:=0;
    for J:=0 to High(FlatPts) do Acc(FlatPts[J].X, FlatPts[J].Y);
    for J:=0 to High(PathCur) do Acc(PathCur[J].X, PathCur[J].Y);
    Result := not First;
  end;
  // True if the current path is a single axis-aligned rectangle — then the clip
  // rectangle bbox fully describes it and no polygon clip path is needed.
  function CurPathIsRect: Boolean;
  var Pts: array of TPdfPathPoint;
    J, nx, ny: Integer;
    bx1,by1,bx2,by2: Double;
  begin
    Result := False;
    // Collapse flushed + in-progress points (clip uses the whole current path).
    if (Length(PathSubs) > 1) then Exit;  // more than one subpath
    SetLength(Pts, Length(FlatPts) + Length(PathCur));
    for J := 0 to High(FlatPts) do Pts[J] := FlatPts[J];
    for J := 0 to High(PathCur) do Pts[Length(FlatPts)+J] := PathCur[J];
    // Accept 4 corners, or 5 where the last repeats the first.
    if (Length(Pts) = 5) and (Abs(Pts[4].X-Pts[0].X)<1e-6) and (Abs(Pts[4].Y-Pts[0].Y)<1e-6) then
      SetLength(Pts, 4);
    if Length(Pts) <> 4 then Exit;
    bx1:=Pts[0].X;
    bx2:=Pts[0].X;
    by1:=Pts[0].Y;
    by2:=Pts[0].Y;
    for J:=1 to 3 do begin
      if Pts[J].X<bx1 then bx1:=Pts[J].X;
      if Pts[J].X>bx2 then bx2:=Pts[J].X;
      if Pts[J].Y<by1 then by1:=Pts[J].Y;
      if Pts[J].Y>by2 then by2:=Pts[J].Y;
    end;
    // Every corner must sit on an extreme X and an extreme Y (axis-aligned).
    nx := 0;
    ny := 0;
    for J:=0 to 3 do begin
      if (Abs(Pts[J].X-bx1)<1e-6) or (Abs(Pts[J].X-bx2)<1e-6) then Inc(nx);
      if (Abs(Pts[J].Y-by1)<1e-6) or (Abs(Pts[J].Y-by2)<1e-6) then Inc(ny);
    end;
    Result := (nx=4) and (ny=4) and (bx2>bx1) and (by2>by1);
  end;
  // Snapshot the current path geometry (page space) for a non-rect clip.
  procedure SnapshotClipPath;
  var Base, M, I, N: Integer;
  begin
    PendingClipHasPath := False;
    SetLength(PendingClipPts, 0);
    SetLength(PendingClipSubs, 0);
    if CurPathIsRect then Exit;  // rect bbox already describes it
    // Copy flushed subpaths.
    PendingClipPts := Copy(FlatPts);
    PendingClipSubs := Copy(PathSubs);
    // Append the in-progress subpath (if any) as a closed range.
    if Length(PathCur) > 0 then
    begin
      Base := Length(PendingClipPts);
      M := Length(PathCur);
      SetLength(PendingClipPts, Base + M);
      for I := 0 to M-1 do PendingClipPts[Base+I] := PathCur[I];
      N := Length(PendingClipSubs);
      SetLength(PendingClipSubs, N+1);
      PendingClipSubs[N].StartIdx := Base;
      PendingClipSubs[N].Count := M;
      PendingClipSubs[N].Closed := True;
    end;
    PendingClipHasPath := Length(PendingClipSubs) > 0;
  end;
  // Intersect the pending clip rectangle into the graphics state (after a paint op).
  procedure ApplyPendingClip;
  var CP: TPdfClipPath;
    N: Integer;
  begin
    if not PendingClip then Exit;
    PendingClip := False;
    if GS.Current.HasClip then
    begin
      if PClipX1 > GS.Current.ClipX1 then GS.Current.ClipX1 := PClipX1;
      if PClipY1 > GS.Current.ClipY1 then GS.Current.ClipY1 := PClipY1;
      if PClipX2 < GS.Current.ClipX2 then GS.Current.ClipX2 := PClipX2;
      if PClipY2 < GS.Current.ClipY2 then GS.Current.ClipY2 := PClipY2;
    end
    else
    begin
      GS.Current.HasClip := True;
      GS.Current.ClipX1 := PClipX1;
      GS.Current.ClipY1 := PClipY1;
      GS.Current.ClipX2 := PClipX2;
      GS.Current.ClipY2 := PClipY2;
    end;
    // Non-rectangular clip path: store it on the page and push a ref onto the GS.
    if PendingClipHasPath then
    begin
      CP := TPdfClipPath.Create;
      CP.Points := Copy(PendingClipPts);
      CP.SubPaths := Copy(PendingClipSubs);
      CP.EvenOdd := PendingClipEO;
      Page.ClipPaths.Add(CP);
      N := Length(GS.Current.ClipPaths);
      SetLength(GS.Current.ClipPaths, N+1);
      GS.Current.ClipPaths[N] := CP;
      PendingClipHasPath := False;
    end;
  end;
  // Emit the accumulated path as a page element, then clear it.
  procedure PathPaint(AFill, AStroke, AEvenOdd, ACloseFirst: Boolean);
  var E: TPdfPathElement;
    Scale: Double;
  begin
    if ACloseFirst then PathClose;
    PathFlushSub(False);
    if Length(PathSubs) > 0 then
    if AFill or AStroke then
    begin
      E := TPdfPathElement.Create;
      E.Points := FlatPts;  // hand over the flat point buffer
      E.SubPaths := PathSubs;  // and the subpath ranges
      E.DoFill := AFill;
      E.DoStroke := AStroke;
      E.EvenOdd := AEvenOdd;
      E.FillR := GS.Current.FillR;
      E.FillG := GS.Current.FillG;
      E.FillB := GS.Current.FillB;
      E.StrokeR := GS.Current.StrokeR;
      E.StrokeG := GS.Current.StrokeG;
      E.StrokeB := GS.Current.StrokeB;
      Scale := Sqrt(Abs(GS.Current.CTM.A * GS.Current.CTM.D - GS.Current.CTM.B * GS.Current.CTM.C));
      if Scale <= 0 then Scale := 1;
      E.LineWidth := GS.Current.LineWidth * Scale;
      SetElemClip(E);
      Page.Elements.Add(E);
    end;
    PathSubs := nil;
    FlatPts := nil;
    SetLength(PathCur, 0);
    PathHasCur := False;
  end;
  // Apply an ExtGState referenced by `gs`: we only care about its soft mask.
  procedure ApplyExtGState(const GSName: string);
  var EG, GSObj, SM: TPdfObject;
    NewMask: TPdfSoftMask;
  begin
    if not Assigned(Resources) then Exit;
    EG := ResolveObject(Resources.Get('ExtGState'));
    if not (EG is TPdfDictionaryObject) then Exit;
    GSObj := ResolveObject(TPdfDictionaryObject(EG).Get(GSName));
    if not (GSObj is TPdfDictionaryObject) then Exit;
    // SMask present? /None disables; a dict enables. Absent = leave unchanged.
    SM := TPdfDictionaryObject(GSObj).Get('SMask');
    if Assigned(SM) then
    begin
      SM := ResolveObject(SM);
      if (SM is TPdfDictionaryObject) and not FBuildingMask then
      begin
        NewMask := BuildSoftMask(Page, TPdfDictionaryObject(SM), GS.Current.CTM);
        Page.SoftMasks.Add(NewMask);
        GS.Current.SoftMask := NewMask;
      end
      else
        // /None: a form invoked under a mask keeps it (its own /None must not
        // re-expose what the parent meant to mask); otherwise clear.
        GS.Current.SoftMask := InheritedMask;
    end;
  end;
  // Set fill (AFill=True) or stroke colour from however many numeric operands
  // are currently on the stack: 1=gray, 3=RGB, 4=CMYK. Used by sc/scn/SC/SCN.
  procedure SetColorFromStack(AFill: Boolean);
  var Nums: array of Double;
    I, C: Integer;
    r,g,b: Double;
  begin
    SetLength(Nums, 0);
    for I := 0 to Stack.Count - 1 do
      if TOperand(Stack[I]).Obj is TPdfNumberObject then
      begin
        C := Length(Nums);
        SetLength(Nums, C+1);
        Nums[C] := TOperand(Stack[I]).Obj.AsNumber;
      end;
    C := Length(Nums);
    if C = 1 then begin
      r := Nums[0];
      g := Nums[0];
      b := Nums[0];
    end
    else if C = 3 then begin
      r := Nums[0];
      g := Nums[1];
      b := Nums[2];
    end
    else if C = 4 then begin
      r := (1-Nums[0])*(1-Nums[3]);
      g := (1-Nums[1])*(1-Nums[3]);
      b := (1-Nums[2])*(1-Nums[3]);
    end
    else Exit;
    if AFill then begin
      GS.Current.FillR:=r;
      GS.Current.FillG:=g;
      GS.Current.FillB:=b;
    end
    else begin
      GS.Current.StrokeR:=r;
      GS.Current.StrokeG:=g;
      GS.Current.StrokeB:=b;
    end;
  end;
var T: string;
  V: Double;
  O1,O2,O3,O4,O5,O6: TPdfObject;
    ArrI: Integer;
    CatStr: AnsiString;
    ArrObj: TPdfArrayObject;
    ErrCode: Integer;
    ImgE: TPdfImageElement;
    FormRes: TPdfDictionaryObject;
    FormCTM: TPdfMatrix;
    ShEl: TPdfShadingElement;
begin
  S := BytesToAnsi(Bytes);
  P := 1;
  Stack := TObjectList.Create(True);
  GS := TPdfGraphicsStack.Create;
  GS.Current.CTM := InitialCTM;
  GS.Current.SoftMask := InitialSoftMask;
  Fonts := BuildFontMap(Resources);
  InheritedMask := InitialSoftMask;
  // Preserve any caller's in-progress path (this call may be nested form/mask
  // interpretation), then start with a fresh path of our own.
  SavedSubs := PathSubs;
  SavedFlat := FlatPts;
  SavedCur := PathCur;
  PathSubs := nil;
  FlatPts := nil;
  PathCur := nil;
  PathHasCur := False;
  UserX := 0;
  UserY := 0;
  StartUserX := 0;
  StartUserY := 0;
  PendingClip := False;
  PClipX1 := 0;
  PClipY1 := 0;
  PClipX2 := 0;
  PClipY2 := 0;
  PendingClipHasPath := False;
  PendingClipEO := False;
  SetLength(PendingClipPts, 0);
  SetLength(PendingClipSubs, 0);
  try
    repeat
      T := NextToken;
      if T='' then Break;
      if T[1]='/' then PushObj(TPdfNameObject.Create(Copy(T,2,MaxInt)))
      else if T[1]='(' then PushObj(TPdfStringObject.Create(UnescapeLitStr(T)))
      // Inline dict operand: <<...>> (e.g. BDC property list) — push empty placeholder
      else if (Length(T) >= 4) and (T[1]='<') and (T[2]='<') then
        PushObj(TPdfDictionaryObject.Create)
      // Hex string operand: <HHHH> — common in Type0/CID fonts
      else if (Length(T) >= 2) and (T[1]='<') and (T[Length(T)]='>') then
        PushObj(TPdfStringObject.Create(HexStrToAnsi(T)))
      // Array start marker (used by TJ)
      else if T='[' then PushObj(TPdfNameObject.Create('['))
      // Array end: collect stack items back to the '[' marker into a TPdfArrayObject
      else if T=']' then begin
        ArrObj := TPdfArrayObject.Create;
        O1 := PopObj;
        while Assigned(O1) and not ((O1.Kind=pokName) and (O1.AsName='[')) do begin
          ArrObj.Items.Insert(0, O1);
          O1 := PopObj;
        end;
        O1.Free;  // free the '[' sentinel
        PushObj(ArrObj);
      end
      else begin
        // Use Val so PDF's '.' decimal separator works regardless of OS locale
        Val(T, V, ErrCode);
        if ErrCode = 0 then PushObj(TPdfNumberObject.Create(V, pokReal))
        else if T='q' then begin
          GS.Save;
          Clear;
        end
        else if T='Q' then begin
          GS.Restore;
          Clear;
        end
        else if T='cm' then begin
          O6:=PopObj;
          O5:=PopObj;
          O4:=PopObj;
          O3:=PopObj;
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then GS.Current.CTM := PdfMatrixMultiply(PdfMatrixFrom(O1.AsNumber,O2.AsNumber,O3.AsNumber,O4.AsNumber,O5.AsNumber,O6.AsNumber), GS.Current.CTM);
          O1.Free;
          O2.Free;
          O3.Free;
          O4.Free;
          O5.Free;
          O6.Free;
        end
        else if T='BT' then begin
          GS.Current.TextMatrix := PdfIdentityMatrix;
          GS.Current.TextLineMatrix := PdfIdentityMatrix;
          Clear;
        end
        else if T='ET' then Clear
        else if T='Tf' then begin
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then GS.Current.FontName:=O1.AsName;
          if Assigned(O2) then GS.Current.FontSize:=O2.AsNumber;
          O1.Free;
          O2.Free;
        end
        else if T='Tm' then begin
          O6:=PopObj;
          O5:=PopObj;
          O4:=PopObj;
          O3:=PopObj;
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then begin
            GS.Current.TextMatrix := PdfMatrixFrom(O1.AsNumber,O2.AsNumber,O3.AsNumber,O4.AsNumber,O5.AsNumber,O6.AsNumber);
            GS.Current.TextLineMatrix := GS.Current.TextMatrix;
          end;
          O1.Free;
          O2.Free;
          O3.Free;
          O4.Free;
          O5.Free;
          O6.Free;
        end
        else if (T='Td') or (T='TD') then begin
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then begin
            GS.Current.TextLineMatrix := PdfMatrixMultiply(PdfMatrixTranslate(O1.AsNumber,O2.AsNumber), GS.Current.TextLineMatrix);
            GS.Current.TextMatrix := GS.Current.TextLineMatrix;
          end;
          O1.Free;
          O2.Free;
        end
        else if T='T*' then begin
          GS.Current.TextLineMatrix := PdfMatrixMultiply(PdfMatrixTranslate(0,-GS.Current.Leading), GS.Current.TextLineMatrix);
          GS.Current.TextMatrix := GS.Current.TextLineMatrix;
        end
        else if T='Tj' then begin
          O1:=PopObj;
          ShowText(ObjStr(O1));
          O1.Free;
        end
        // TJ: array of strings (text) and numbers (kerning adjustments)
        else if T='TJ' then begin
          O1 := PopObj;
          if O1 is TPdfArrayObject then begin
            CatStr := '';
            for ArrI := 0 to TPdfArrayObject(O1).Items.Count - 1 do begin
              O2 := TPdfObject(TPdfArrayObject(O1).Items[ArrI]);
              if O2.Kind = pokString then CatStr := CatStr + O2.AsString;
            end;
            ShowText(CatStr);
          end;
          O1.Free;
        end
        // ' operator: move to next line and show text
        else if T='''' then begin
          GS.Current.TextLineMatrix := PdfMatrixMultiply(PdfMatrixTranslate(0,-GS.Current.Leading), GS.Current.TextLineMatrix);
          GS.Current.TextMatrix := GS.Current.TextLineMatrix;
          O1 := PopObj;
          ShowText(ObjStr(O1));
          O1.Free;
        end
        else if T='Tc' then begin
          O1:=PopObj;
          if Assigned(O1) then GS.Current.CharSpacing:=O1.AsNumber;
          O1.Free;
        end
        else if T='Tw' then begin
          O1:=PopObj;
          if Assigned(O1) then GS.Current.WordSpacing:=O1.AsNumber;
          O1.Free;
        end
        else if T='TL' then begin
          O1:=PopObj;
          if Assigned(O1) then GS.Current.Leading:=O1.AsNumber;
          O1.Free;
        end
        else if T='Ts' then begin
          O1:=PopObj;
          if Assigned(O1) then GS.Current.TextRise:=O1.AsNumber;
          O1.Free;
        end
        else if T='Do' then
        begin
          O1 := PopObj;
          if Assigned(O1) then
          begin
            ImgE := TPdfImageElement.Create;
            ImgE.Name   := O1.AsName;
            ImgE.Matrix := GS.Current.CTM;
            if Assigned(Resources) then
            begin
              O2 := ResolveObject(Resources.Get('XObject'));
              if O2 is TPdfDictionaryObject then
              begin
                O3 := ResolveObject(TPdfDictionaryObject(O2).Get(ImgE.Name));
                if O3 is TPdfStreamObject then
                begin
                  if SameText(TPdfStreamObject(O3).GetName('Subtype'), 'Image') then
                  begin
                    ImgE.Width  := Trunc(TPdfStreamObject(O3).GetNumber('Width'));
                    ImgE.Height := Trunc(TPdfStreamObject(O3).GetNumber('Height'));
                    ImgE.BitsPerComponent := Trunc(TPdfStreamObject(O3).GetNumber('BitsPerComponent', 8));
                    // ColorSpace can be a name (/DeviceRGB) or an array
                    // ([/ICCBased ref] or [/Indexed base hival lookup]).
                    O4 := ResolveObject(TPdfStreamObject(O3).Get('ColorSpace'));
                    if Assigned(O4) then
                    begin
                      if O4.Kind = pokName then
                        ImgE.ColorSpace := O4.AsName
                      else if O4 is TPdfArrayObject then
                      begin
                        if TPdfArrayObject(O4).Items.Count > 0 then
                          ImgE.ColorSpace := TPdfObject(TPdfArrayObject(O4).Items[0]).AsName;
                        if SameText(ImgE.ColorSpace, 'Indexed') or SameText(ImgE.ColorSpace, 'I') then
                        begin
                          ImgE.ColorSpace := 'Indexed';
                          ImgE.PaletteCount := BuildIndexedRGBPalette(TPdfArrayObject(O4), ImgE.Palette);
                        end;
                      end;
                    end;
                    ImgE.Data := TPdfStreamObject(O3).DecodedData;
                    SetElemClip(ImgE);
                    Page.Elements.Add(ImgE);
                    ImgE := nil;  // ownership transferred
                  end
                  else if SameText(TPdfStreamObject(O3).GetName('Subtype'), 'Form') then
                  begin
                    // Effective starting CTM = parent CTM × form's own /Matrix (default identity).
                    FormCTM := GS.Current.CTM;
                    O5 := ResolveObject(TPdfStreamObject(O3).Get('Matrix'));
                    if (O5 is TPdfArrayObject) and (TPdfArrayObject(O5).Items.Count >= 6) then
                      FormCTM := PdfMatrixMultiply(FormCTM, PdfMatrixFrom(
                        TPdfObject(TPdfArrayObject(O5).Items[0]).AsNumber,
                        TPdfObject(TPdfArrayObject(O5).Items[1]).AsNumber,
                        TPdfObject(TPdfArrayObject(O5).Items[2]).AsNumber,
                        TPdfObject(TPdfArrayObject(O5).Items[3]).AsNumber,
                        TPdfObject(TPdfArrayObject(O5).Items[4]).AsNumber,
                        TPdfObject(TPdfArrayObject(O5).Items[5]).AsNumber));
                    // Use the form's own Resources when present; fall back to page resources.
                    O4 := ResolveObject(TPdfStreamObject(O3).Get('Resources'));
                    if O4 is TPdfDictionaryObject then
                      FormRes := TPdfDictionaryObject(O4)
                    else
                      FormRes := Resources;
                    InterpretContent(Page, TPdfStreamObject(O3).DecodedData, FormRes, FormCTM, GS.Current.SoftMask, CurMark);
                  end;
                end;
              end;
            end;
            ImgE.Free;  // free if not transferred (non-image XObject or failed lookup)
            ImgE := nil;
          end;
          O1.Free;
        end
        else if T='BI' then InlineImage
        // Marked content operators. Each BDC/BMC opens a block with a fresh unique
        // id pushed on MarkStack; EMC pops it. Elements created in between record
        // the id (via SetElemClip→CurMark) so a whole figure's vectors group together.
        else if T='BDC' then begin
          O2:=PopObj;
          O1:=PopObj;
          O2.Free;
          O1.Free;
            Inc(FMarkCounter);
            SetLength(MarkStack, Length(MarkStack)+1);
            MarkStack[High(MarkStack)]:=FMarkCounter;
          end
        else if T='BMC' then begin
          O1:=PopObj;
          O1.Free;
            Inc(FMarkCounter);
            SetLength(MarkStack, Length(MarkStack)+1);
            MarkStack[High(MarkStack)]:=FMarkCounter;
          end
        else if T='EMC' then begin
          if Length(MarkStack)>0 then SetLength(MarkStack, Length(MarkStack)-1);
        end
        else if T='MP' then begin
        end
        else if T='DP' then begin
          O2:=PopObj;
          O1:=PopObj;
          O2.Free;
          O1.Free;
        end
        // Non-stroking gray: g  (0=black, 1=white)
        else if T='g' then begin
          O1:=PopObj;
          if Assigned(O1) then begin
            GS.Current.FillR:=O1.AsNumber;
            GS.Current.FillG:=O1.AsNumber;
            GS.Current.FillB:=O1.AsNumber;
          end;
          O1.Free;
        end
        // Non-stroking RGB: rg
        else if T='rg' then begin
          O3:=PopObj;
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then begin
            GS.Current.FillR:=O1.AsNumber;
            GS.Current.FillG:=O2.AsNumber;
            GS.Current.FillB:=O3.AsNumber;
          end;
          O3.Free;
          O2.Free;
          O1.Free;
        end
        // Non-stroking CMYK: k  (C M Y K — O1=C, O2=M, O3=Y, O4=K after pop-reverse)
        else if T='k' then begin
          O4:=PopObj;
          O3:=PopObj;
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then begin
            GS.Current.FillR:=(1-O1.AsNumber)*(1-O4.AsNumber);
            GS.Current.FillG:=(1-O2.AsNumber)*(1-O4.AsNumber);
            GS.Current.FillB:=(1-O3.AsNumber)*(1-O4.AsNumber);
          end;
          O4.Free;
          O3.Free;
          O2.Free;
          O1.Free;
        end
        // Line width: w
        else if T='w' then begin
          O1:=PopObj;
          if Assigned(O1) then GS.Current.LineWidth:=O1.AsNumber;
          O1.Free;
        end
        // Stroking gray: G
        else if T='G' then begin
          O1:=PopObj;
          if Assigned(O1) then begin
            GS.Current.StrokeR:=O1.AsNumber;
            GS.Current.StrokeG:=O1.AsNumber;
            GS.Current.StrokeB:=O1.AsNumber;
          end;
          O1.Free;
        end
        // ExtGState: track soft-mask activation
        else if T='gs' then begin
          O1:=PopObj;
          if Assigned(O1) then ApplyExtGState(O1.AsName);
          O1.Free;
        end
        // Other 1-operand graphics operators — discard
        else if T='Tr' then begin
          O1:=PopObj;
          if Assigned(O1) then GS.Current.TextRenderMode:=Round(O1.AsNumber);
          O1.Free;
        end
        else if (T='ri') or (T='i') or
                (T='J') or (T='j') or (T='M') or
                (T='cs') or (T='CS') or
                (T='Tz') then begin
                  O1:=PopObj;
                  O1.Free;
                end
        // Stroking RGB: RG
        else if T='RG' then begin
          O3:=PopObj;
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then begin
            GS.Current.StrokeR:=O1.AsNumber;
            GS.Current.StrokeG:=O2.AsNumber;
            GS.Current.StrokeB:=O3.AsNumber;
          end;
          O3.Free;
          O2.Free;
          O1.Free;
        end
        // Stroking CMYK: K
        else if T='K' then begin
          O4:=PopObj;
          O3:=PopObj;
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then begin
            GS.Current.StrokeR:=(1-O1.AsNumber)*(1-O4.AsNumber);
            GS.Current.StrokeG:=(1-O2.AsNumber)*(1-O4.AsNumber);
            GS.Current.StrokeB:=(1-O3.AsNumber)*(1-O4.AsNumber);
          end;
          O4.Free;
          O3.Free;
          O2.Free;
          O1.Free;
        end
        // Path construction
        else if T='m' then begin
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then PathMoveTo(O1.AsNumber,O2.AsNumber);
          O2.Free;
          O1.Free;
        end
        else if T='l' then begin
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then PathLineTo(O1.AsNumber,O2.AsNumber);
          O2.Free;
          O1.Free;
        end
        else if T='c' then begin
          O6:=PopObj;
          O5:=PopObj;
          O4:=PopObj;
          O3:=PopObj;
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then PathCurveTo(O1.AsNumber,O2.AsNumber,O3.AsNumber,O4.AsNumber,O5.AsNumber,O6.AsNumber);
          O6.Free;
          O5.Free;
          O4.Free;
          O3.Free;
          O2.Free;
          O1.Free;
        end
        else if T='v' then begin
          O4:=PopObj;
          O3:=PopObj;
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then PathCurveTo(UserX,UserY,O1.AsNumber,O2.AsNumber,O3.AsNumber,O4.AsNumber);
          O4.Free;
          O3.Free;
          O2.Free;
          O1.Free;
        end
        else if T='y' then begin
          O4:=PopObj;
          O3:=PopObj;
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then PathCurveTo(O1.AsNumber,O2.AsNumber,O3.AsNumber,O4.AsNumber,O3.AsNumber,O4.AsNumber);
          O4.Free;
          O3.Free;
          O2.Free;
          O1.Free;
        end
        else if T='re' then begin
          O4:=PopObj;
          O3:=PopObj;
          O2:=PopObj;
          O1:=PopObj;
          if Assigned(O1) then PathRect(O1.AsNumber,O2.AsNumber,O3.AsNumber,O4.AsNumber);
          O4.Free;
          O3.Free;
          O2.Free;
          O1.Free;
        end
        // Path painting (then apply any clip that a preceding W/W* requested)
        else if T='h' then begin
          PathClose;
          Clear;
        end
        else if (T='f') or (T='F') then begin
          PathPaint(True, False, False, False);
          ApplyPendingClip;
          Clear;
        end
        else if T='f*' then begin
          PathPaint(True, False, True, False);
          ApplyPendingClip;
          Clear;
        end
        else if T='S' then begin
          PathPaint(False, True, False, False);
          ApplyPendingClip;
          Clear;
        end
        else if T='s' then begin
          PathPaint(False, True, False, True);
          ApplyPendingClip;
          Clear;
        end
        else if T='B' then begin
          PathPaint(True, True, False, False);
          ApplyPendingClip;
          Clear;
        end
        else if T='B*' then begin
          PathPaint(True, True, True, False);
          ApplyPendingClip;
          Clear;
        end
        else if T='b' then begin
          PathPaint(True, True, False, True);
          ApplyPendingClip;
          Clear;
        end
        else if T='b*' then begin
          PathPaint(True, True, True, True);
          ApplyPendingClip;
          Clear;
        end
        else if T='n' then begin
          PathReset;
          ApplyPendingClip;
          Clear;
        end
        // Clipping: mark the current path's bounding box as the pending clip region.
        else if (T='W') or (T='W*') then begin
          if CurPathBBox(PClipX1,PClipY1,PClipX2,PClipY2) then begin
            PendingClip := True;
            PendingClipEO := (T='W*');
            SnapshotClipPath;
          end;
          Clear;
        end
        // Variable-operand colour
        else if (T='sc') or (T='scn') then begin
          SetColorFromStack(True);
          Clear;
        end
        else if (T='SC') or (T='SCN') then begin
          SetColorFromStack(False);
          Clear;
        end
        // Smooth shading paint: fill the current clip with the named gradient.
        else if T='sh' then
        begin
          O1 := PopObj;
          if Assigned(O1) and Assigned(Resources) then
          begin
            O2 := ResolveObject(Resources.Get('Shading'));
            if O2 is TPdfDictionaryObject then
            begin
              O3 := ResolveObject(TPdfDictionaryObject(O2).Get(O1.AsName));
              if Assigned(O3) then
              begin
                ShEl := BuildShading(O3, GS.Current.CTM);
                if Assigned(ShEl) then begin
                  SetElemClip(ShEl);
                  Page.Elements.Add(ShEl);
                end;
              end;
            end;
          end;
          O1.Free;
          Clear;
        end
        else if T='d' then Clear
        else begin
          Page.Elements.Add(TPdfUnknownElement.Create(T));
          Clear;
        end;
      end;
    until False;
  finally
    PathSubs := SavedSubs;
    FlatPts := SavedFlat;
    PathCur := SavedCur;  // restore caller's path
    Fonts.Free;
    GS.Free;
    Stack.Free;
  end;
end;

function TPdfDocument.Resolve(Obj: TPdfObject): TPdfObject;
begin
  Result := ResolveObject(Obj);
end;


function TPdfDocument.GetCatalog: TPdfDictionaryObject;
var O: TPdfObject;
begin
  Result := nil;
  if not Assigned(FTrailer) then Exit;
  O := ResolveObject(FTrailer.Get('Root'));
  if O is TPdfDictionaryObject then Result := TPdfDictionaryObject(O);
end;

// =-─ PdfFloat / EscapeAnsi helpers =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-─

function PdfFloat(V: Double): AnsiString;
var S: AnsiString;
  I: Integer;
begin
  if Frac(V) = 0 then begin
    Str(Trunc(V), S);
    Result := S;
    Exit;
  end;
  Str(V:0:4, S);
  for I := 1 to Length(S) do if S[I] = ',' then S[I] := '.';
  I := Length(S);
  while (I > 1) and (S[I] = '0') do Dec(I);
  if S[I] = '.' then Dec(I);
  Result := Copy(S, 1, I);
end;

function EscapeAnsi(const A: AnsiString): AnsiString;
var I: Integer;
  C: AnsiChar;
begin
  Result := '';
  for I := 1 to Length(A) do
  begin
    C := A[I];
    case C of
      '(': Result := Result + '\(';
      ')': Result := Result + '\)';
      '\': Result := Result + '\\';
      #13: Result := Result + '\r';
      #10: Result := Result + '\n';
    else  Result := Result + C;
    end;
  end;
end;

// =-─ TPdfDocument: output primitives =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-─

procedure TPdfDocument.WS(const A: AnsiString);
begin
  if A <> '' then FOut.WriteBuffer(A[1], Length(A));
end;
procedure TPdfDocument.WLn(const A: AnsiString);
begin
  WS(A);
  WS(#10);
end;
procedure TPdfDocument.WF(V: Double);
begin
  WS(PdfFloat(V));
end;
procedure TPdfDocument.WI(N: Integer);
var S: string;
begin
  Str(N, S);
  WS(AnsiString(S));
end;

function TPdfDocument.Alloc: Integer;
begin
  Result := FNextNum;
  Inc(FNextNum);
  if Length(FOffsets) < FNextNum then SetLength(FOffsets, FNextNum + 128);
end;

procedure TPdfDocument.StartObj(N: Integer);
begin
  if Length(FOffsets) <= N then SetLength(FOffsets, N + 128);
  FOffsets[N] := FOut.Position;
  WI(N);
  WS(' 0 obj'#10);
end;

procedure TPdfDocument.EndObj;
begin
  WLn('endobj');
  WLn('');
end;

// =-─ AppendObj =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

procedure TPdfDocument.AppendObj(var Buf: AnsiString; O: TPdfObject;
                                 var Deferred: array of TPdfDeferredStream;
                                 var DeferCount: Integer);
var
  I:  Integer;
  RO: TPdfObject;
  D:  TPdfDeferredStream;
  S:  AnsiString;
begin
  if not Assigned(O) then begin
    Buf := Buf + 'null';
    Exit;
  end;

  if O.Kind = pokReference then
  begin
    RO := Resolve(O);
    if not Assigned(RO) then begin
      Buf := Buf + 'null';
      Exit;
    end;
    O := RO;
  end;

  case O.Kind of
    pokNull:    Buf := Buf + 'null';
    pokBoolean: if TPdfNumberObject(O).Value <> 0 then Buf := Buf + 'true'
                else Buf := Buf + 'false';
    pokInteger: begin
      Str(Trunc(TPdfNumberObject(O).Value), S);
      Buf := Buf + AnsiString(S);
    end;
    pokReal:    Buf := Buf + PdfFloat(TPdfNumberObject(O).Value);
    pokName:    Buf := Buf + '/' + AnsiString(TPdfNameObject(O).Value);
    pokString:  Buf := Buf + '(' + EscapeAnsi(TPdfStringObject(O).Value) + ')';
    pokArray:
      begin
        Buf := Buf + '[';
        for I := 0 to TPdfArrayObject(O).Items.Count - 1 do
        begin
          if I > 0 then Buf := Buf + ' ';
          AppendObj(Buf, TPdfObject(TPdfArrayObject(O).Items[I]), Deferred, DeferCount);
        end;
        Buf := Buf + ']';
      end;
    pokStream:
      begin
        if DeferCount >= Length(Deferred) then
          raise Exception.Create('TPdfDocument: deferred stream buffer too small');
        D.ObjNum := Alloc;
        D.Stream := TPdfStreamObject(O);
        D.Owned  := False;
        Deferred[DeferCount] := D;
        Inc(DeferCount);
        Str(D.ObjNum, S);
        Buf := Buf + AnsiString(S) + ' 0 R';
      end;
    pokDictionary:
      begin
        Buf := Buf + '<< ';
        for I := 0 to TPdfDictionaryObject(O).Keys.Count - 1 do
        begin
          Buf := Buf + '/' + AnsiString(TPdfDictionaryObject(O).Keys[I]) + ' ';
          AppendObj(Buf, TPdfObject(TPdfDictionaryObject(O).Keys.Objects[I]),
                    Deferred, DeferCount);
          Buf := Buf + ' ';
        end;
        Buf := Buf + '>>';
      end;
  else
    Buf := Buf + 'null';
  end;
end;

// =-─ BuildResources =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-─

procedure TPdfDocument.BuildResources(Page: TPdfPage; PageIdx: Integer;
                                      var Deferred: array of TPdfDeferredStream;
                                      var DeferCount: Integer;
                                      out ResBuf: AnsiString);
var
  FontObj, XObjEntry, FontEntry, XEntry: TPdfObject;
  FontDict, XDict: TPdfDictionaryObject;
  I, J: Integer;
  D:  TPdfDeferredStream;
  S:  string;
  Sub, Base: AnsiString;
begin
  ResBuf := '<< /ProcSet [/PDF /Text /ImageB /ImageC /ImageI]';

  ResBuf := ResBuf + ' /Font <<';
  if Assigned(Page.Resources) then
  begin
    FontObj := Resolve(Page.Resources.Get('Font'));
    if FontObj is TPdfDictionaryObject then
    begin
      FontDict := TPdfDictionaryObject(FontObj);
      for I := 0 to FontDict.Keys.Count - 1 do
      begin
        FontEntry := Resolve(TPdfObject(FontDict.Keys.Objects[I]));
        if FontEntry is TPdfDictionaryObject then
        begin
          Sub  := AnsiString(TPdfDictionaryObject(FontEntry).GetName('Subtype'));
          Base := AnsiString(TPdfDictionaryObject(FontEntry).GetName('BaseFont'));
          ResBuf := ResBuf + ' /' + AnsiString(FontDict.Keys[I]) +
                    ' << /Type /Font /Subtype /' + Sub +
                    ' /BaseFont /' + Base + ' >>';
        end;
      end;
    end;
  end;
  // Emit font resources used on this page (deduplicated by ResName).
  for I := 0 to High(FExtraTexts[PageIdx]) do
  begin
    J := 0;
    while (J < I) and (FExtraTexts[PageIdx][J].ResName <> FExtraTexts[PageIdx][I].ResName) do
      Inc(J);
    if J < I then Continue;
    with FExtraTexts[PageIdx][I] do
      ResBuf := ResBuf + ' /' + ResName +
                ' << /Type /Font /Subtype /Type1 /BaseFont /' +
                AnsiString(FontName) + ' >>';
  end;
  ResBuf := ResBuf + ' >>';  // end /Font

  ResBuf := ResBuf + ' /XObject <<';
  if Assigned(Page.Resources) then
  begin
    XObjEntry := Resolve(Page.Resources.Get('XObject'));
    if XObjEntry is TPdfDictionaryObject then
    begin
      XDict := TPdfDictionaryObject(XObjEntry);
      for I := 0 to XDict.Keys.Count - 1 do
      begin
        XEntry := Resolve(TPdfObject(XDict.Keys.Objects[I]));
        if XEntry is TPdfStreamObject then
        begin
          if DeferCount >= Length(Deferred) then
            raise Exception.Create('TPdfDocument: deferred buffer overflow');
          D.ObjNum := Alloc;
          D.Stream := TPdfStreamObject(XEntry);
          D.Owned  := False;
          Deferred[DeferCount] := D;
          Inc(DeferCount);
          Str(D.ObjNum, S);
          ResBuf := ResBuf + ' /' + AnsiString(XDict.Keys[I]) + ' ' +
                    AnsiString(S) + ' 0 R';
        end;
      end;
    end;
  end;
  for I := 0 to High(FExtraImages[PageIdx]) do
  begin
    with FExtraImages[PageIdx][I] do
    begin
      if DeferCount >= Length(Deferred) then
        raise Exception.Create('TPdfDocument: deferred buffer overflow');
      D.ObjNum := Alloc;
      D.Owned  := True;
      D.Stream := TPdfStreamObject.Create;
      D.Stream.Add('Type',             TPdfNameObject.Create('XObject'));
      D.Stream.Add('Subtype',          TPdfNameObject.Create('Image'));
      D.Stream.Add('Filter',           TPdfNameObject.Create('DCTDecode'));
      D.Stream.Add('ColorSpace',       TPdfNameObject.Create('DeviceRGB'));
      D.Stream.Add('BitsPerComponent', TPdfNumberObject.Create(8, pokInteger));
      D.Stream.Add('Width',            TPdfNumberObject.Create(Round(W), pokInteger));
      D.Stream.Add('Height',           TPdfNumberObject.Create(Round(H), pokInteger));
      D.Stream.RawData     := JpegData;
      D.Stream.DecodedData := JpegData;
      Deferred[DeferCount] := D;
      Inc(DeferCount);
      Str(D.ObjNum, S);
      ResBuf := ResBuf + ' /' + ResName + ' ' + AnsiString(S) + ' 0 R';
    end;
  end;
  ResBuf := ResBuf + ' >>';  // end /XObject
  ResBuf := ResBuf + ' >>';  // end Resources dict
end;

// =-─ BuildExtraOps =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

function TPdfDocument.BuildExtraOps(PageIdx: Integer): AnsiString;
var I: Integer;
begin
  Result := '';
  for I := 0 to High(FExtraImages[PageIdx]) do
    with FExtraImages[PageIdx][I] do
      Result := Result +
        'q ' + PdfFloat(W) + ' 0 0 ' + PdfFloat(H) + ' ' +
        PdfFloat(X) + ' ' + PdfFloat(Y) + ' cm' + #10 +
        '/' + ResName + ' Do' + #10 + 'Q' + #10;
  for I := 0 to High(FExtraTexts[PageIdx]) do
    with FExtraTexts[PageIdx][I] do
      Result := Result +
        'BT' + #10 +
        '/' + ResName + ' ' + PdfFloat(FontSize) + ' Tf' + #10 +
        PdfFloat(X) + ' ' + PdfFloat(Y) + ' Td' + #10 +
        '(' + EscapeAnsi(AnsiString(Text)) + ') Tj' + #10 +
        'ET' + #10;
  if PageIdx <= High(FExtraRects) then
    for I := 0 to High(FExtraRects[PageIdx]) do
      with FExtraRects[PageIdx][I] do
        Result := Result +
          'q ' + PdfFloat(R) + ' ' + PdfFloat(G) + ' ' + PdfFloat(B) + ' rg' + #10 +
          PdfFloat(X) + ' ' + PdfFloat(Y) + ' ' + PdfFloat(W) + ' ' + PdfFloat(H) + ' re' + #10 +
          'f Q' + #10;
end;

// =-─ WriteDeferredStream =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

procedure TPdfDocument.WriteDeferredStream(const D: TPdfDeferredStream);
var
  Data:  TPdfBytes;
  I:     Integer;
  Dummy: Integer;
  Buf:   AnsiString;
  DeferDummy: array[0..0] of TPdfDeferredStream;
begin
  StartObj(D.ObjNum);
  Data := D.Stream.DecodedData;
  WS('<< ');
  Dummy := 0;
  for I := 0 to D.Stream.Keys.Count - 1 do
  begin
    if SameText(D.Stream.Keys[I], 'Filter') or
       SameText(D.Stream.Keys[I], 'DecodeParms') or
       SameText(D.Stream.Keys[I], 'Length') then Continue;
    WS('/');
    WS(AnsiString(D.Stream.Keys[I]));
    WS(' ');
    Buf := '';
    AppendObj(Buf, TPdfObject(D.Stream.Keys.Objects[I]), DeferDummy, Dummy);
    WS(Buf);
    WS(' ');
  end;
  if SameText(D.Stream.GetName('Filter'), 'DCTDecode') then
    WS('/Filter /DCTDecode ');
  WS('/Length ');
  WI(Length(Data));
  WLn(' >>');
  WLn('stream');
  if Length(Data) > 0 then FOut.WriteBuffer(Data[0], Length(Data));
  WLn('');
  WLn('endstream');
  EndObj;
  if D.Owned then D.Stream.Free;
end;

// =-─ SyncPageArrays =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

procedure TPdfDocument.SyncPageArrays;
var N: Integer;
begin
  N := FPages.Count;
  SetLength(FRemoved,     N);
  SetLength(FExtraImages, N);
  SetLength(FExtraTexts,  N);
  SetLength(FExtraRects,  N);
  FFontResCount := 0;
end;

// =-─ InitFromBlankPage =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

procedure TPdfDocument.InitFromBlankPage(APageWidth, APageHeight: Double);
var
  TmpFile : string;
  FS      : TFileStream;
  Off     : array[1..4] of Int64;
  XRefPos : Int64;

  function PadOff(V: Int64): AnsiString;
  begin
    Result := AnsiString(IntToStr(V));
    while Length(Result) < 10 do Result := '0' + Result;
  end;

  procedure W(const S: AnsiString);
  begin
    if S <> '' then FS.Write(S[1], Length(S));
  end;

begin
  TmpFile := IncludeTrailingPathDelimiter(GetTempDir) + 'xelpdf_blank.pdf';
  FS := TFileStream.Create(TmpFile, fmCreate);
  try
    W('%PDF-1.4' + #10);
    W('%' + #$E2#$E3#$CF#$D3 + #10);
    Off[1] := FS.Position;
    W('1 0 obj' + #10 + '<< /Type /Catalog /Pages 2 0 R >>' + #10 + 'endobj' + #10);
    Off[2] := FS.Position;
    W('2 0 obj' + #10 + '<< /Type /Pages /Kids [3 0 R] /Count 1 >>' + #10 + 'endobj' + #10);
    Off[3] := FS.Position;
    W('3 0 obj' + #10);
    W('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 '
      + PdfFloat(APageWidth) + ' ' + PdfFloat(APageHeight) + ']'
      + ' /Resources << /ProcSet [/PDF /Text] >>'
      + ' /Contents 4 0 R >>' + #10 + 'endobj' + #10);
    Off[4] := FS.Position;
    W('4 0 obj' + #10 + '<< /Length 0 >>' + #10
      + 'stream' + #10 + 'endstream' + #10 + 'endobj' + #10);
    XRefPos := FS.Position;
    W('xref' + #10 + '0 5' + #10);
    W('0000000000 65535 f' + #13#10);
    W(PadOff(Off[1]) + ' 00000 n' + #13#10);
    W(PadOff(Off[2]) + ' 00000 n' + #13#10);
    W(PadOff(Off[3]) + ' 00000 n' + #13#10);
    W(PadOff(Off[4]) + ' 00000 n' + #13#10);
    W('trailer' + #10 + '<< /Size 5 /Root 1 0 R >>' + #10);
    W('startxref' + #10 + AnsiString(IntToStr(XRefPos)) + #10 + '%%EOF' + #10);
  finally
    FS.Free;
  end;
  LoadFromFile(TmpFile);
  DeleteFile(TmpFile);
  // LoadFromFile already called SyncPageArrays
end;

// =-─ Constructors =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-─

constructor TPdfDocument.Create(APageWidth, APageHeight: Double);
begin
  inherited Create;
  FPages       := TObjectList.Create(True);
  FObjectCache := TFPHashObjectList.Create(True);
  FRenderZoom  := 1.0;
  InitFromBlankPage(APageWidth, APageHeight);
end;

// =-─ Public writer interface =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-

procedure TPdfDocument.RemovePage(PageIndex: Integer);
begin
  if (PageIndex >= 0) and (PageIndex < Length(FRemoved)) then
    FRemoved[PageIndex] := True;
end;

function TPdfDocument.AddPage(AWidth, AHeight: Double): Integer;
var Page: TPdfPage;
begin
  Page             := TPdfPage.Create;
  Page.Width       := AWidth;
  Page.Height      := AHeight;
  Page.MediaBox.X1 := 0;
  Page.MediaBox.Y1 := 0;
  Page.MediaBox.X2 := AWidth;
  Page.MediaBox.Y2 := AHeight;
  Page.CropBox     := Page.MediaBox;
  FPages.Add(Page);
  Result := FPages.Count - 1;
  SetLength(FRemoved,     FPages.Count);
  SetLength(FExtraImages, FPages.Count);
  SetLength(FExtraTexts,  FPages.Count);
end;

procedure TPdfDocument.AddJpegImage(PageIndex: Integer; const JpegData: TPdfBytes;
                                    X, Y, W, H: Double);
var Idx: Integer;
  Img: TPdfExtraImage;
begin
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  Idx := Length(FExtraImages[PageIndex]);
  SetLength(FExtraImages[PageIndex], Idx + 1);
  Img.JpegData := JpegData;
  Img.X := X;
  Img.Y := Y;
  Img.W := W;
  Img.H := H;
  Img.ResName  := AnsiString(Format('WImg%d', [Idx]));
  FExtraImages[PageIndex][Idx] := Img;
end;

function TPdfDocument.AddFont(const FontName: string; FontSize: Double): AnsiString;
var I: Integer;
begin
  for I := 0 to FFontResCount - 1 do
    if (FFontResources[I].FontName = FontName) and
       (Abs(FFontResources[I].FontSize - FontSize) < 0.001) then
    begin
      Result := FFontResources[I].ResName;
      Exit;
    end;
  if FFontResCount >= Length(FFontResources) then
    SetLength(FFontResources, FFontResCount + 16);
  FFontResources[FFontResCount].FontName := FontName;
  FFontResources[FFontResCount].FontSize := FontSize;
  FFontResources[FFontResCount].ResName  := AnsiString(Format('WFnt%d', [FFontResCount]));
  Result := FFontResources[FFontResCount].ResName;
  Inc(FFontResCount);
end;

procedure TPdfDocument.AddText(PageIndex: Integer; const Text: string;
                               X, Y: Double; const FontRes: AnsiString);
var Idx, I: Integer;
  Txt: TPdfExtraText;
begin
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  Txt.FontName := 'Helvetica';
  Txt.FontSize := 12;
  for I := 0 to FFontResCount - 1 do
    if FFontResources[I].ResName = FontRes then
    begin
      Txt.FontName := FFontResources[I].FontName;
      Txt.FontSize := FFontResources[I].FontSize;
      Break;
    end;
  Idx := Length(FExtraTexts[PageIndex]);
  SetLength(FExtraTexts[PageIndex], Idx + 1);
  Txt.Text    := Text;
  Txt.X       := X;
  Txt.Y       := Y;
  Txt.ResName := FontRes;
  FExtraTexts[PageIndex][Idx] := Txt;
end;

procedure TPdfDocument.ExtractTextToFile(PageIndex: Integer; const FileName: string);
var
  Page: TPdfPage;
  I: Integer;
  E: TPdfPageElement;
  FS: TFileStream;
  Chunk: UTF8String;
  HavePos: Boolean;
  LastY: Double;
begin
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  Page := TPdfPage(FPages[PageIndex]);
  Page.EnsureParsed;
  FS := TFileStream.Create(FileName, fmCreate);
  try
    HavePos := False;
    LastY := 0;
    for I := 0 to Page.Elements.Count - 1 do
    begin
      E := TPdfPageElement(Page.Elements[I]);
      if not (E is TPdfTextElement) then Continue;
      if HavePos and (Abs(E.Matrix.F - LastY) > 1) then
      begin
        Chunk := UTF8String(#10);
        FS.WriteBuffer(Chunk[1], Length(Chunk));
      end;
      LastY := E.Matrix.F;
      HavePos := True;
      Chunk := UTF8Encode(TPdfTextElement(E).Text);
      if Length(Chunk) > 0 then FS.WriteBuffer(Chunk[1], Length(Chunk));
    end;
    Chunk := UTF8String(#10);
    FS.WriteBuffer(Chunk[1], Length(Chunk));
  finally
    FS.Free;
  end;
end;

procedure TPdfDocument.SaveToStream(AStream: TStream);
const
  MaxDeferred = 4096;
var
  Page:         TPdfPage;
  I, J, ActiveCount, PageI: Integer;
  PageNums, ContentNums: array of Integer;
  CatalogNum, PagesNum:  Integer;
  Deferred:     array[0..MaxDeferred - 1] of TPdfDeferredStream;
  DeferCount:   Integer;
  ResBuf:       AnsiString;
  ExtraOps:     AnsiString;
  Content:      TPdfBytes;
  XRefPos:      Int64;
  ObjCount:     Integer;
  XS:           string;
begin
  FOut     := AStream;
  FNextNum := 1;
  SetLength(FOffsets, 256);
  try
    ActiveCount := 0;
    for I := 0 to FPages.Count - 1 do
      if not FRemoved[I] then Inc(ActiveCount);

    CatalogNum := Alloc;
    PagesNum   := Alloc;

    SetLength(PageNums,    ActiveCount);
    SetLength(ContentNums, ActiveCount);
    PageI := 0;
    for I := 0 to FPages.Count - 1 do
      if not FRemoved[I] then
      begin
        PageNums[PageI]    := Alloc;
        ContentNums[PageI] := Alloc;
        Inc(PageI);
      end;

    WLn('%PDF-1.4');
    WLn('%'#$E2#$E3#$CF#$D3);

    StartObj(CatalogNum);
    WS('<< /Type /Catalog /Pages ');
    WI(PagesNum);
    WLn(' 0 R >>');
    EndObj;

    StartObj(PagesNum);
    WS('<< /Type /Pages /Count ');
    WI(ActiveCount);
    WS(' /Kids [');
    for I := 0 to ActiveCount - 1 do
    begin
      if I > 0 then WS(' ');
      WI(PageNums[I]);
      WS(' 0 R');
    end;
    WLn('] >>');
    EndObj;

    PageI := 0;
    for I := 0 to FPages.Count - 1 do
    begin
      if FRemoved[I] then Continue;
      Page     := TPdfPage(FPages[I]);
      Page.EnsureParsed;  // need RawContent (set during content parse)
      ExtraOps := BuildExtraOps(I);
      Content  := Page.RawContent;

      StartObj(ContentNums[PageI]);
      WS('<< /Length ');
      WI(Length(Content) + Length(ExtraOps));
      WLn(' >>');
      WLn('stream');
      if Length(Content)  > 0 then FOut.WriteBuffer(Content[0],  Length(Content));
      if Length(ExtraOps) > 0 then FOut.WriteBuffer(ExtraOps[1], Length(ExtraOps));
      WLn('');
      WLn('endstream');
      EndObj;

      DeferCount := 0;
      BuildResources(Page, I, Deferred, DeferCount, ResBuf);

      StartObj(PageNums[PageI]);
      WS('<< /Type /Page /Parent ');
      WI(PagesNum);
      WS(' 0 R');
      WS(' /MediaBox [');
      WF(Page.MediaBox.X1);
      WS(' ');
      WF(Page.MediaBox.Y1);
      WS(' ');
      WF(Page.MediaBox.X2);
      WS(' ');
      WF(Page.MediaBox.Y2);
      WS(']');
      WS(' /Contents ');
      WI(ContentNums[PageI]);
      WS(' 0 R');
      WS(' /Resources ');
      WS(ResBuf);
      WLn(' >>');
      EndObj;

      for J := 0 to DeferCount - 1 do
        WriteDeferredStream(Deferred[J]);

      Inc(PageI);
    end;

    ObjCount := FNextNum;
    if Length(FOffsets) < ObjCount then SetLength(FOffsets, ObjCount);
    XRefPos := FOut.Position;
    WLn('xref');
    WS('0 ');
    WI(ObjCount);
    WLn('');
    WLn('0000000000 65535 f ');
    for I := 1 to ObjCount - 1 do
    begin
      Str(FOffsets[I]:10, XS);
      for J := 1 to Length(XS) do if XS[J] = ' ' then XS[J] := '0';
      WS(AnsiString(XS));
      WLn(' 00000 n ');
    end;

    WLn('trailer');
    WS('<< /Size ');
    WI(ObjCount);
    WS(' /Root ');
    WI(CatalogNum);
    WLn(' 0 R >>');
    WLn('startxref');
    WI(XRefPos);
    WLn('');
    WS('%%EOF');

  finally
    FOut := nil;
  end;
end;

procedure TPdfDocument.SaveToFile(const FileName: string);
var FS: TFileStream;
begin
  FS := TFileStream.Create(FileName, fmCreate);
  try
    SaveToStream(FS);
  finally
    FS.Free;
  end;
end;

// ════════════════════════════════════════════════════════════════════════════
//  Added API: font / image / vector queries, exports, edit, render, import
// ════════════════════════════════════════════════════════════════════════════

function ImgIsJpeg(E: TPdfImageElement): Boolean;
begin
  Result := (Length(E.Data) >= 3) and (E.Data[0] = $FF) and (E.Data[1] = $D8) and (E.Data[2] = $FF);
end;

// Recursively gather distinct embedded font-program streams from a resources dict
// (its /Font, plus the resources of any /XObject form). Seen dedups streams AND
// already-visited form streams (so recursion can't loop).
procedure TPdfDocument.CollectFontsFrom(Res: TPdfObject; Seen: TList);
var fonts, xobj, fd, fdesc, ff, df, xo: TPdfObject;
  i: Integer;
  sub: string;
begin
  Res := ResolveObject(Res);
  if not (Res is TPdfDictionaryObject) then Exit;
  fonts := ResolveObject(TPdfDictionaryObject(Res).Get('Font'));
  if fonts is TPdfDictionaryObject then
    for i := 0 to TPdfDictionaryObject(fonts).Keys.Count - 1 do
    begin
      fd := ResolveObject(TPdfDictionaryObject(fonts).Get(TPdfDictionaryObject(fonts).Keys[i]));
      if not (fd is TPdfDictionaryObject) then Continue;
      fdesc := ResolveObject(TPdfDictionaryObject(fd).Get('FontDescriptor'));
      if not (fdesc is TPdfDictionaryObject) then
      begin
        df := ResolveObject(TPdfDictionaryObject(fd).Get('DescendantFonts'));
        if (df is TPdfArrayObject) and (TPdfArrayObject(df).Items.Count > 0) then
          df := ResolveObject(TPdfObject(TPdfArrayObject(df).Items[0]));
        if df is TPdfDictionaryObject then
          fdesc := ResolveObject(TPdfDictionaryObject(df).Get('FontDescriptor'));
      end;
      if not (fdesc is TPdfDictionaryObject) then Continue;
      ff := ResolveObject(TPdfDictionaryObject(fdesc).Get('FontFile2'));
      sub := 'tt';
      if not (ff is TPdfStreamObject) then
      begin
        ff := ResolveObject(TPdfDictionaryObject(fdesc).Get('FontFile3'));
        if ff is TPdfStreamObject then
        begin
          sub := TPdfStreamObject(ff).GetName('Subtype');
          if not (SameText(sub,'Type1C') or SameText(sub,'CIDFontType0C') or SameText(sub,'OpenType')) then
            ff := nil;
        end
        else ff := nil;
      end
      else sub := 'tt';
      if (ff is TPdfStreamObject) and (Seen.IndexOf(ff) < 0) then
      begin
        Seen.Add(ff);
        SetLength(FFontList, Length(FFontList)+1);
        FFontList[High(FFontList)].Stream   := TPdfStreamObject(ff);
        FFontList[High(FFontList)].IsCFF    := SameText(sub,'Type1C') or SameText(sub,'CIDFontType0C');
        FFontList[High(FFontList)].BaseFont := TPdfDictionaryObject(fd).GetName('BaseFont');
      end;
    end;
  xobj := ResolveObject(TPdfDictionaryObject(Res).Get('XObject'));
  if xobj is TPdfDictionaryObject then
    for i := 0 to TPdfDictionaryObject(xobj).Keys.Count - 1 do
    begin
      xo := ResolveObject(TPdfDictionaryObject(xobj).Get(TPdfDictionaryObject(xobj).Keys[i]));
      if (xo is TPdfStreamObject) and SameText(TPdfStreamObject(xo).GetName('Subtype'),'Form')
         and (Seen.IndexOf(xo) < 0) then
      begin
        Seen.Add(xo);
        CollectFontsFrom(ResolveObject(TPdfStreamObject(xo).Get('Resources')), Seen);
      end;
    end;
end;

procedure TPdfDocument.BuildFontList;
var Seen: TList;
  i: Integer;
begin
  if FFontListBuilt then Exit;
  FFontListBuilt := True;
  SetLength(FFontList, 0);
  Seen := TList.Create;
  try
    for i := 0 to FPages.Count - 1 do
      CollectFontsFrom(TPdfPage(FPages[i]).Resources, Seen);
  finally
    Seen.Free;
  end;
end;

function TPdfDocument.FontsCount: Integer;
begin
  BuildFontList;
  Result := Length(FFontList);
end;

procedure TPdfDocument.ExportFont(Index: Integer; const FileName: string);
var data, otf: TPdfBytes;
  FS: TFileStream;
begin
  BuildFontList;
  if (Index < 0) or (Index >= Length(FFontList)) then Exit;
  data := FFontList[Index].Stream.DecodedData;
  if FFontList[Index].IsCFF then
  begin
    otf := WrapCFFToOTF(data, AnsiString(FFontList[Index].BaseFont));
    if Length(otf) > 0 then data := otf;  // else fall back to writing raw CFF
  end
  else
    // TrueType/OpenType: PDF-embedded subsets often drop cmap/post, which makes
    // Windows refuse to open the file. Re-add minimal tables so it opens.
    data := EnsureFontTables(data);
  if Length(data) = 0 then Exit;
  FS := TFileStream.Create(FileName, fmCreate);
  try
    FS.WriteBuffer(data[0], Length(data));
  finally
    FS.Free;
  end;
end;

function TPdfDocument.VectorsCount(PageIndex: Integer): Integer;
var pg: TPdfPage;
  i: Integer;
begin
  Result := 0;
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  pg := TPdfPage(FPages[PageIndex]);
  pg.EnsureParsed;
  for i := 0 to pg.Elements.Count - 1 do
    if TPdfPageElement(pg.Elements[i]) is TPdfPathElement then Inc(Result);
end;

type
  TPathArr    = array of TPdfPathElement;
  TPathGroups = array of TPathArr;

// Emit a list of path elements as one SVG (one <path> node per element, each
// keeping its own fill/stroke). Shared by ExportVector and ExportVectorGroup.
procedure WritePathsSVG(pg: TPdfPage; const Elems: TPathArr; const FileName: string);
var FS: TFileStream;
  s, d, attrs: AnsiString;
  PW, PH: Double;
  n, j, k: Integer;
  E: TPdfPathElement;
  function FN(V: Double): AnsiString;
  begin
    Result := AnsiString(PdfFloat(V));
  end;
  function Hex(R, G, B: Double): AnsiString;
  begin
    Result := '#' + AnsiString(IntToHex(EnsureRange(Round(R*255),0,255),2)
                                  + IntToHex(EnsureRange(Round(G*255),0,255),2)
                                    + IntToHex(EnsureRange(Round(B*255),0,255),2));
                                  end;
begin
  PW := pg.MediaBox.X2 - pg.MediaBox.X1;
  PH := pg.MediaBox.Y2 - pg.MediaBox.Y1;
  s := '<?xml version="1.0" encoding="UTF-8"?>'#10 +
       '<svg xmlns="http://www.w3.org/2000/svg" width="' + FN(PW) + '" height="' + FN(PH) +
       '" viewBox="0 0 ' + FN(PW) + ' ' + FN(PH) + '">'#10;
  for n := 0 to High(Elems) do
  begin
    E := Elems[n];
    if E = nil then Continue;
    // SVG path data (flip Y: PDF origin bottom-left, SVG top-left).
    d := '';
    for j := 0 to High(E.SubPaths) do
    begin
      if E.SubPaths[j].Count < 1 then Continue;
      d := d + 'M ' + FN(E.Points[E.SubPaths[j].StartIdx].X - pg.MediaBox.X1) + ' '
                    + FN(PH - (E.Points[E.SubPaths[j].StartIdx].Y - pg.MediaBox.Y1)) + ' ';
      for k := 1 to E.SubPaths[j].Count - 1 do
        d := d + 'L ' + FN(E.Points[E.SubPaths[j].StartIdx + k].X - pg.MediaBox.X1) + ' '
                      + FN(PH - (E.Points[E.SubPaths[j].StartIdx + k].Y - pg.MediaBox.Y1)) + ' ';
      if E.SubPaths[j].Closed then d := d + 'Z ';
    end;
    if d = '' then Continue;
    attrs := '';
    if E.DoFill then
    begin
      attrs := attrs + 'fill="' + Hex(E.FillR, E.FillG, E.FillB) + '" ';
      if E.EvenOdd then attrs := attrs + 'fill-rule="evenodd" ';
    end
    else attrs := attrs + 'fill="none" ';
    if E.DoStroke then
      attrs := attrs + 'stroke="' + Hex(E.StrokeR, E.StrokeG, E.StrokeB) + '" stroke-width="' + FN(E.LineWidth) + '" '
    else attrs := attrs + 'stroke="none" ';
    s := s + '  <path d="' + d + '" ' + attrs + '/>'#10;
  end;
  s := s + '</svg>'#10;
  FS := TFileStream.Create(FileName, fmCreate);
  try
    if Length(s) > 0 then FS.WriteBuffer(s[1], Length(s));
  finally
    FS.Free;
  end;
end;

// Page-space bounding box of a path element (False if it has no points).
function PathBBox(E: TPdfPathElement; out x1, y1, x2, y2: Double): Boolean;
var j, k, idx: Integer;
  px, py: Double;
  first: Boolean;
begin
  Result := False;
  x1 := 0;
  y1 := 0;
  x2 := 0;
  y2 := 0;
  first := True;
  for j := 0 to High(E.SubPaths) do
    for k := 0 to E.SubPaths[j].Count - 1 do
    begin
      idx := E.SubPaths[j].StartIdx + k;
      px := E.Points[idx].X;
      py := E.Points[idx].Y;
      if first then begin
        x1 := px;
        x2 := px;
        y1 := py;
        y2 := py;
        first := False;
      end
      else begin
        if px < x1 then x1 := px;
        if px > x2 then x2 := px;
        if py < y1 then y1 := py;
        if py > y2 then y2 := py;
      end;
      Result := True;
    end;
end;

// Decide whether path element B continues the same logical drawing/caption as A.
// Primary signal: marked content (both inside the same BDC block). Fallback for
// untagged content: same fill colour, overlapping vertical band and small
// horizontal gap — i.e. adjacent glyphs of one word on a baseline.
function SamePathGroup(A, B: TPdfPathElement): Boolean;
var ax1,ay1,ax2,ay2, bx1,by1,bx2,by2, H, gap, ovl: Double;
begin
  Result := False;
  // Marked content takes precedence: identical block id = one figure.
  if (A.Mark >= 0) or (B.Mark >= 0) then
  begin
    Result := (A.Mark >= 0) and (A.Mark = B.Mark);
    Exit;
  end;
  // Untagged: geometric/colour heuristic. Glyph outlines are fills.
  if not (A.DoFill and B.DoFill) then Exit;
  if (Abs(A.FillR-B.FillR) > 0.02) or (Abs(A.FillG-B.FillG) > 0.02)
     or (Abs(A.FillB-B.FillB) > 0.02) then Exit;
  if not PathBBox(A, ax1,ay1,ax2,ay2) then Exit;
  if not PathBBox(B, bx1,by1,bx2,by2) then Exit;
  H := ay2 - ay1;
  if (by2-by1) > H then H := by2 - by1;
  if H <= 0 then Exit;
  // vertical overlap of the two bands
  ovl := Min(ay2, by2) - Max(ay1, by1);
  if ovl < 0.3*H then Exit;
  // horizontal gap from A's right edge to B's left edge (allow slight kerning overlap)
  gap := bx1 - ax2;
  Result := (gap >= -0.6*H) and (gap <= 1.2*H);
end;

// Cluster a page's path elements into logical groups (in content order).
function BuildVectorGroups(pg: TPdfPage): TPathGroups;
var i, np, gi: Integer;
  paths: TPathArr;
  Prev, E: TPdfPathElement;
begin
  Result := nil;
  np := 0;
  SetLength(paths, pg.Elements.Count);
  for i := 0 to pg.Elements.Count - 1 do
    if TPdfPageElement(pg.Elements[i]) is TPdfPathElement then
    begin
      paths[np] := TPdfPathElement(pg.Elements[i]);
      Inc(np);
    end;
  SetLength(paths, np);
  i := 0;
  while i < np do
  begin
    SetLength(Result, Length(Result)+1);
    gi := High(Result);
    SetLength(Result[gi], 1);
    Result[gi][0] := paths[i];
    Prev := paths[i];
    Inc(i);
    while (i < np) and SamePathGroup(Prev, paths[i]) do
    begin
      E := paths[i];
      SetLength(Result[gi], Length(Result[gi])+1);
      Result[gi][High(Result[gi])] := E;
      Prev := E;
      Inc(i);
    end;
  end;
end;

procedure TPdfDocument.ExportVector(PageIndex, Index: Integer; const FileName: string);
var pg: TPdfPage;
  i, cnt: Integer;
  E: TPdfPathElement;
  one: TPathArr;
begin
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  pg := TPdfPage(FPages[PageIndex]);
  pg.EnsureParsed;
  E := nil;
  cnt := -1;
  for i := 0 to pg.Elements.Count - 1 do
    if TPdfPageElement(pg.Elements[i]) is TPdfPathElement then
    begin
      Inc(cnt);
      if cnt = Index then begin
        E := TPdfPathElement(pg.Elements[i]);
        Break;
      end;
    end;
  if E = nil then Exit;
  SetLength(one, 1);
  one[0] := E;
  WritePathsSVG(pg, one, FileName);
end;

function TPdfDocument.VectorGroupsCount(PageIndex: Integer): Integer;
var pg: TPdfPage;
begin
  Result := 0;
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  pg := TPdfPage(FPages[PageIndex]);
  pg.EnsureParsed;
  Result := Length(BuildVectorGroups(pg));
end;

procedure TPdfDocument.ExportVectorGroup(PageIndex, GroupIndex: Integer; const FileName: string);
var pg: TPdfPage;
  groups: TPathGroups;
begin
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  pg := TPdfPage(FPages[PageIndex]);
  pg.EnsureParsed;
  groups := BuildVectorGroups(pg);
  if (GroupIndex < 0) or (GroupIndex >= Length(groups)) then Exit;
  WritePathsSVG(pg, groups[GroupIndex], FileName);
end;

function TPdfDocument.JpegsCount(PageIndex: Integer): Integer;
var pg: TPdfPage;
  i: Integer;
  E: TPdfPageElement;
begin
  Result := 0;
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  pg := TPdfPage(FPages[PageIndex]);
  pg.EnsureParsed;
  for i := 0 to pg.Elements.Count - 1 do
  begin
    E := TPdfPageElement(pg.Elements[i]);
    if (E is TPdfImageElement) and ImgIsJpeg(TPdfImageElement(E)) then Inc(Result);
  end;
end;

function TPdfDocument.ImagesCount(PageIndex: Integer): Integer;
var pg: TPdfPage;
  i: Integer;
  E: TPdfPageElement;
begin
  Result := 0;
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  pg := TPdfPage(FPages[PageIndex]);
  pg.EnsureParsed;
  for i := 0 to pg.Elements.Count - 1 do
  begin
    E := TPdfPageElement(pg.Elements[i]);
    if (E is TPdfImageElement) and not ImgIsJpeg(TPdfImageElement(E)) then Inc(Result);
  end;
end;

// Find the Index-th image element on a page (WantJpeg selects jpeg vs non-jpeg).
function NthImage(pg: TPdfPage; Index: Integer; WantJpeg: Boolean): TPdfImageElement;
var i, cnt: Integer;
  E: TPdfPageElement;
begin
  Result := nil;
  cnt := -1;
  for i := 0 to pg.Elements.Count - 1 do
  begin
    E := TPdfPageElement(pg.Elements[i]);
    if not (E is TPdfImageElement) then Continue;
    if ImgIsJpeg(TPdfImageElement(E)) <> WantJpeg then Continue;
    Inc(cnt);
    if cnt = Index then Exit(TPdfImageElement(E));
  end;
end;

// Number of colour components in a JPEG (from its SOFn marker); 0 if not found.
function JpegComponents(const D: TPdfBytes): Integer;
var i: Integer;
begin
  Result := 0;
  i := 2;  // skip SOI
  while i+1 < Length(D) do
  begin
    if D[i] <> $FF then begin
      Inc(i);
      Continue;
    end;
    case D[i+1] of
      $C0,$C1,$C2,$C3,$C5,$C6,$C7,$C9,$CA,$CB,$CD,$CE,$CF:   // SOFn
        begin
          if i+9 < Length(D) then Result := D[i+9];
          Exit;
        end;
      $D8,$D9,$01,$D0,$D1,$D2,$D3,$D4,$D5,$D6,$D7: Inc(i, 2);  // markers w/o length
    else
      if i+3 < Length(D) then Inc(i, 2 + (D[i+2]*256 + D[i+3])) else Exit;
    end;
  end;
end;

procedure TPdfDocument.ExportJpeg(PageIndex, Index: Integer; const FileName: string);
var pg: TPdfPage;
  E: TPdfImageElement;
  FS: TFileStream;
    W, H, x, y, o: Integer;
    RGB: TPdfBytes;
    img: TFPMemoryImage;
    wr: TFPWriterJPEG;
begin
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  pg := TPdfPage(FPages[PageIndex]);
  pg.EnsureParsed;
  E := NthImage(pg, Index, True);
  if (E = nil) or (Length(E.Data) = 0) then Exit;
  // A CMYK/Adobe JPEG (4 components) shows up as a colour negative in normal
  // viewers, so decode it (PdfJpeg handles the Adobe inversion) and re-encode as
  // a plain RGB JPEG. Ordinary RGB/grayscale JPEGs are written byte-for-byte.
  if (SameText(E.ColorSpace,'DeviceCMYK') or (JpegComponents(E.Data) = 4))
     and DecodeJpegToRGB(E.Data, W, H, RGB) and (W > 0) and (H > 0) then
  begin
    img := TFPMemoryImage.Create(W, H);
    wr  := TFPWriterJPEG.Create;
    try
      for y := 0 to H-1 do
        for x := 0 to W-1 do
        begin
          o := (y*W+x)*3;
          img.Colors[x,y] := FPColor(RGB[o]*257, RGB[o+1]*257, RGB[o+2]*257, $FFFF);
        end;
      img.SaveToFile(FileName, wr);
    finally
      wr.Free;
      img.Free;
    end;
  end
  else
  begin
    FS := TFileStream.Create(FileName, fmCreate);
    try
      FS.WriteBuffer(E.Data[0], Length(E.Data));
    finally
      FS.Free;
    end;
  end;
end;

function TPdfDocument.DecodeRasterToRGB(E: TPdfImageElement; out RGB: TPdfBytes): Boolean;
var W, H, bpc, stride, x, y, idx, bitpos, bytepos, shift, mask: Integer;
    cs: string;
    c, m, yy, k, o: Integer;
begin
  Result := False;
  RGB := nil;
  W := E.Width;
  H := E.Height;
  if (W <= 0) or (H <= 0) then Exit;
  cs := E.ColorSpace;
  bpc := E.BitsPerComponent;
  if bpc <= 0 then bpc := 8;
  SetLength(RGB, W*H*3);
  if SameText(cs,'DeviceRGB') or SameText(cs,'RGB') or SameText(cs,'CalRGB') then
  begin
    if Length(E.Data) < W*H*3 then Exit;
    Move(E.Data[0], RGB[0], W*H*3);
    Result := True;
  end
  else if SameText(cs,'DeviceCMYK') or SameText(cs,'CMYK') then
  begin
    if Length(E.Data) < W*H*4 then Exit;
    for y := 0 to H-1 do for x := 0 to W-1 do
    begin
      o := (y*W+x);
      c := E.Data[o*4];
      m := E.Data[o*4+1];
      yy := E.Data[o*4+2];
      k := E.Data[o*4+3];
      RGB[o*3+0] := (255-c)*(255-k) div 255;
      RGB[o*3+1] := (255-m)*(255-k) div 255;
      RGB[o*3+2] := (255-yy)*(255-k) div 255;
    end;
    Result := True;
  end
  else if SameText(cs,'Indexed') or SameText(cs,'I') then
  begin
    stride := (W*bpc+7) div 8;
    if (Length(E.Data) < stride*H) or (E.PaletteCount <= 0) or (Length(E.Palette) < E.PaletteCount*3) then Exit;
    mask := (1 shl bpc)-1;
    for y := 0 to H-1 do for x := 0 to W-1 do
    begin
      if bpc = 8 then idx := E.Data[y*stride+x]
      else begin
        bitpos := x*bpc;
        bytepos := y*stride+(bitpos div 8);
        shift := 8-bpc-(bitpos mod 8);
        idx := (E.Data[bytepos] shr shift) and mask;
      end;
      if idx >= E.PaletteCount then idx := E.PaletteCount-1;
      o := (y*W+x);
      RGB[o*3+0] := E.Palette[idx*3+0];
      RGB[o*3+1] := E.Palette[idx*3+1];
      RGB[o*3+2] := E.Palette[idx*3+2];
    end;
    Result := True;
  end
  else // DeviceGray / CalGray / unspecified
  begin
    stride := (W*bpc+7) div 8;
    if Length(E.Data) < stride*H then Exit;
    mask := (1 shl bpc)-1;
    if mask = 0 then mask := 1;
    for y := 0 to H-1 do for x := 0 to W-1 do
    begin
      if bpc = 8 then idx := E.Data[y*stride+x]
      else begin
        bitpos := x*bpc;
        bytepos := y*stride+(bitpos div 8);
        shift := 8-bpc-(bitpos mod 8);
        idx := ((E.Data[bytepos] shr shift) and mask)*255 div mask;
      end;
      o := (y*W+x);
      RGB[o*3+0] := idx;
      RGB[o*3+1] := idx;
      RGB[o*3+2] := idx;
    end;
    Result := True;
  end;
end;

procedure TPdfDocument.ExportImage(PageIndex, Index: Integer; const FileName: string);
var pg: TPdfPage;
  E: TPdfImageElement;
  RGB: TPdfBytes;
  Bmp: TBitmap;
  Png: TPortableNetworkGraphic;
    x, y: Integer;
    Dst: PByte;
begin
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  pg := TPdfPage(FPages[PageIndex]);
  pg.EnsureParsed;
  E := NthImage(pg, Index, False);
  if E = nil then Exit;
  if not DecodeRasterToRGB(E, RGB) then Exit;
  Bmp := TBitmap.Create;
  try
    Bmp.PixelFormat := pf24bit;
    Bmp.SetSize(E.Width, E.Height);
    for y := 0 to E.Height-1 do
    begin
      Dst := Bmp.ScanLine[y];
      for x := 0 to E.Width-1 do
      begin
        Dst[x*3+0] := RGB[(y*E.Width+x)*3+2];  // B
        Dst[x*3+1] := RGB[(y*E.Width+x)*3+1];  // G
        Dst[x*3+2] := RGB[(y*E.Width+x)*3+0];  // R
      end;
    end;
    Png := TPortableNetworkGraphic.Create;
    try
      Png.Assign(Bmp);
      Png.SaveToFile(FileName);
    finally
      Png.Free;
    end;
  finally
    Bmp.Free;
  end;
end;

procedure TPdfDocument.DrawRect(PageIndex: Integer; X, Y, W, H: Double; Color: TColor);
var idx, rgb: Integer;
  pg: TPdfPage;
  pe: TPdfPathElement;
  rr, gg, bb: Double;
begin
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  if Length(FExtraRects) < FPages.Count then SetLength(FExtraRects, FPages.Count);
  rgb := ColorToRGB(Color);
  rr := (rgb and $FF)/255;
  gg := ((rgb shr 8) and $FF)/255;
  bb := ((rgb shr 16) and $FF)/255;
  // Persisted edit (written into the page content on Save).
  idx := Length(FExtraRects[PageIndex]);
  SetLength(FExtraRects[PageIndex], idx+1);
  FExtraRects[PageIndex][idx].X := X;
  FExtraRects[PageIndex][idx].Y := Y;
  FExtraRects[PageIndex][idx].W := W;
  FExtraRects[PageIndex][idx].H := H;
  FExtraRects[PageIndex][idx].R := rr;
  FExtraRects[PageIndex][idx].G := gg;
  FExtraRects[PageIndex][idx].B := bb;
  // Live element so it renders immediately (not only after Save+reload).
  pg := TPdfPage(FPages[PageIndex]);
  pg.EnsureParsed;
  pe := TPdfPathElement.Create;
  pe.DoFill := True;
  pe.FillR := rr;
  pe.FillG := gg;
  pe.FillB := bb;
  SetLength(pe.Points, 4);
  SetLength(pe.SubPaths, 1);
  pe.Points[0].X := X;
  pe.Points[0].Y := Y;
  pe.Points[1].X := X+W;
  pe.Points[1].Y := Y;
  pe.Points[2].X := X+W;
  pe.Points[2].Y := Y+H;
  pe.Points[3].X := X;
  pe.Points[3].Y := Y+H;
  pe.SubPaths[0].StartIdx := 0;
  pe.SubPaths[0].Count := 4;
  pe.SubPaths[0].Closed := True;
  pg.Elements.Add(pe);
end;

procedure TPdfDocument.RenderPageToPng(PageIndex: Integer; const FileName: string);
var R: TPdfBitmapRenderer;
  Bmp: TBitmap;
  Png: TPortableNetworkGraphic;
  o: TPdfBitmapRenderOptions;
begin
  if (PageIndex < 0) or (PageIndex >= FPages.Count) then Exit;
  R := TPdfBitmapRenderer.Create;
  try
    o := R.Options;
    o.Scale := FRenderZoom;
    R.Options := o;
    Bmp := R.RenderPageToBitmap(TPdfPage(FPages[PageIndex]));
    try
      Png := TPortableNetworkGraphic.Create;
      try
        Png.Assign(Bmp);
        Png.SaveToFile(FileName);
      finally
        Png.Free;
      end;
    finally
      Bmp.Free;
    end;
  finally
    R.Free;
  end;
end;

procedure TPdfDocument.Zoom(Scale: Extended);
begin
  if Scale > 0 then FRenderZoom := Scale;
end;

// Import pages [PageFrom..PageTo] of the PDF in Str, inserting them after page
// ImportAfterPage (use -1 to prepend). The source document is kept alive and each
// imported page parses against IT (its own object space), so the pages render
// with full fidelity (embedded fonts, images, etc.). NOTE: re-saving the merged
// document uses the writer, which is lossy for resources — see SaveToStream.
procedure TPdfDocument.ImportPDF(Str: TStream; PageFrom, PageTo, ImportAfterPage: Integer);
var src: TPdfDocument;
  i, insertAt, fromP, toP: Integer;
  sp, np: TPdfPage;
begin
  if Str = nil then Exit;
  src := TPdfDocument.Create;
  try
    src.LoadFromStream(Str);
  except
    src.Free;
    Exit;
  end;
  if FImported = nil then FImported := TObjectList.Create(True);
  FImported.Add(src);  // owns src; freed with this document

  fromP := PageFrom;
  if fromP < 0 then fromP := 0;
  toP := PageTo;
  if toP > src.Pages.Count - 1 then toP := src.Pages.Count - 1;
  insertAt := ImportAfterPage + 1;
  if insertAt < 0 then insertAt := 0;
  if insertAt > FPages.Count then insertAt := FPages.Count;

  for i := fromP to toP do
  begin
    sp := TPdfPage(src.Pages[i]);
    np := TPdfPage.Create;
    np.MediaBox  := sp.MediaBox;
    np.CropBox := sp.CropBox;
    np.Width     := sp.Width;
    np.Height  := sp.Height;
    np.Resources := sp.Resources;  // belongs to src
    np.PageDict  := sp.PageDict;  // belongs to src
    np.OwnerDoc  := src;  // parse against the source object space
    np.Parsed    := False;
    FPages.Insert(insertAt, np);
    Inc(insertAt);
  end;
  SyncPageArrays;
end;

end.
