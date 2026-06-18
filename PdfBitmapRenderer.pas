unit PdfBitmapRenderer;
{$mode delphi}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
interface

uses
  //Windows is listed before Graphics/Math so its clashing identifiers (TBitmap,
  //Min, Max, the Rect type) are overridden by the LCL/Math units that follow,
  //while its raw GDI calls (PolyPolygon, clip regions) — which the LCL canvas
  //does not expose — stay reachable.
  SysUtils, Classes, Windows, Graphics, StrUtils, Math, PdfTypes, PdfParser, PdfJpeg, PdfCFF;

type
  TPdfBitmapRenderOptions = record
    Scale: Double;  // pixels per PDF point; 1.0 = 72 DPI
    BackgroundColor: TColor;
    TextColor: TColor;
    StrokeColor: TColor;
    ImagePlaceholderColor: TColor;
    DrawImagePlaceholders: Boolean;
    DrawUnknownPlaceholders: Boolean;
    AntialiasVectors: Boolean;  // draw vector paths via GDI+ (antialiased); GDI fallback
  end;

  TLoadedFontEntry = record
    BaseFont: string;
    ProgSig: LongWord;         // signature of the embedded program (disambiguates
                               // subsets that share a BaseFont name, e.g. several
                               // distinct "ArialMT-Identity-H" CID subsets)
    GDIHandle: Pointer;
    FamilyName: string;
    Subfamily: string;
    CidToGid: array of Word;   // non-empty for CID-keyed CFF: maps CID -> GID
  end;

  TPdfBitmapRenderer = class
  private
    FOptions: TPdfBitmapRenderOptions;
    FLoadedFonts: array of TLoadedFontEntry;
    function PageToBitmapX(const Page: TPdfPage; X: Double): Integer;
    function PageToBitmapY(const Page: TPdfPage; Y: Double): Integer;
    function MatrixScaleX(const M: TPdfMatrix): Double;
    function MatrixScaleY(const M: TPdfMatrix): Double;
    function LoadTTFont(const BaseFont: string; const Data: TPdfBytes): Integer;
    procedure DrawTextElement(Bitmap: TBitmap; Page: TPdfPage; E: TPdfTextElement);
    procedure DrawGlyphRun(Bitmap: TBitmap; E: TPdfTextElement; X, Y, CacheIdx: Integer; DC: HDC);
    procedure DrawImageElement(Bitmap: TBitmap; Page: TPdfPage; E: TPdfImageElement);
    procedure DrawImageAlpha(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
    procedure DrawRawDeviceGray(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
    procedure DrawRawDeviceRGB(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
    procedure DrawRawDeviceCMYK(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
    procedure DrawIndexedImage(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
    procedure DrawJpegImage(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
    procedure DrawPathElement(Bitmap: TBitmap; Page: TPdfPage; E: TPdfPathElement);
    function DrawPathGdiPlus(Bitmap: TBitmap; Page: TPdfPage; E: TPdfPathElement): Boolean;
    function BuildClipCoverage(Mask: TBitmap; Page: TPdfPage; E: TPdfPageElement; OffX, OffY: Integer): Boolean;
    procedure DrawShadingElement(Bitmap: TBitmap; Page: TPdfPage; E: TPdfShadingElement);
    procedure DrawElementRaw(Bitmap: TBitmap; Page: TPdfPage; E: TPdfPageElement);
    procedure DrawMaskedElement(Bitmap: TBitmap; Page: TPdfPage; E: TPdfPageElement);
    function IntersectClipPaths(Page: TPdfPage; E: TPdfPageElement; BaseRgn: HRGN): HRGN;
    procedure EnsureMaskGray(Mask: TPdfSoftMask);
    procedure DrawPlaceholder(Bitmap: TBitmap; const R: TRect; const Caption: string);
  public
    constructor Create;
    destructor Destroy;
    override;
    class function DefaultOptions: TPdfBitmapRenderOptions;
    static;

    property Options: TPdfBitmapRenderOptions read FOptions write FOptions;

    procedure RenderPageToBitmap(Page: TPdfPage; Bitmap: TBitmap);
    overload;
    function RenderPageToBitmap(Page: TPdfPage): TBitmap;
    overload;
    procedure RenderDocumentToBitmaps(Doc: TPdfDocument; List: TList);
  end;

implementation

// GDI font-from-memory API — declared without the Windows unit to avoid its
// TBitmap/Rect redefinitions conflicting with Graphics.TBitmap.
function AddFontMemResourceEx(pFileView: Pointer; cjSize: LongWord;
  pvReserved: Pointer; pNumFonts: PLongWord): Pointer;
  stdcall;
  external 'gdi32.dll' name 'AddFontMemResourceEx';
function RemoveFontMemResourceEx(fh: Pointer): LongBool;
stdcall;
  external 'gdi32.dll' name 'RemoveFontMemResourceEx';
// Per-pixel alpha compositing — in msimg32.dll, not declared by FPC's Windows unit.
function AlphaBlend(hdcDest: HDC; xDest, yDest, wDest, hDest: Integer;
  hdcSrc: HDC; xSrc, ySrc, wSrc, hSrc: Integer; blend: TBlendFunction): LongBool;
  stdcall;
  external 'msimg32.dll' name 'AlphaBlend';

// ── GDI+ flat API (gdiplus.dll) — used to draw vector paths with ANTIALIASING.
// GDI has no antialiasing, so fills/strokes get jagged edges; GDI+ smooths them.
// This is an additional renderer: the existing GDI path code stays as a fallback.
type
  GpStatus   = Integer;
  GpGraphics = Pointer;
  GpPath     = Pointer;
  GpBrush    = Pointer;
  GpPen      = Pointer;
  ARGB       = LongWord;
  TGpPointF  = record
    X, Y: Single;
  end;
  TGdiplusStartupInput = record
    GdiplusVersion: LongWord;
    DebugEventCallback: Pointer;
    SuppressBackgroundThread: LongBool;
    SuppressExternalCodecs: LongBool;
  end;
const
  SmoothingModeAntiAlias = 4;
  FillModeAlternate = 0;  // even-odd
  FillModeWinding   = 1;  // nonzero
  UnitPixel = 2;
  LineJoinRound = 2;
function GdiplusStartup(out token: ULONG_PTR; const input: TGdiplusStartupInput; output: Pointer): GpStatus;
stdcall;
external 'gdiplus.dll';
procedure GdiplusShutdown(token: ULONG_PTR);
stdcall;
external 'gdiplus.dll';
function GdipCreateFromHDC(hdc: HDC; out graphics: GpGraphics): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipDeleteGraphics(graphics: GpGraphics): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipSetSmoothingMode(graphics: GpGraphics; mode: Integer): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipCreatePath(brushMode: Integer; out path: GpPath): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipDeletePath(path: GpPath): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipSetPathFillMode(path: GpPath; mode: Integer): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipStartPathFigure(path: GpPath): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipClosePathFigure(path: GpPath): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipAddPathLine2(path: GpPath; const points: TGpPointF; count: Integer): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipCreateSolidFill(color: ARGB; out brush: GpBrush): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipDeleteBrush(brush: GpBrush): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipFillPath(graphics: GpGraphics; brush: GpBrush; path: GpPath): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipCreatePen1(color: ARGB; width: Single; unit_: Integer; out pen: GpPen): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipDeletePen(pen: GpPen): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipSetPenLineJoin(pen: GpPen; lineJoin: Integer): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipDrawPath(graphics: GpGraphics; pen: GpPen; path: GpPath): GpStatus;
stdcall;
external 'gdiplus.dll';
function GdipSetClipPath(graphics: GpGraphics; path: GpPath; combineMode: Integer): GpStatus;
stdcall;
external 'gdiplus.dll';
const CombineModeIntersect = 1;

// GDI+ high-quality image scaling — GDI's StretchBlt only offers nearest/halftone;
// GDI+ does proper (pre-filtered) bicubic, far smoother for up- and down-scaling.
type
  GpImage  = Pointer;
  GpBitmap = Pointer;
function GdipCreateBitmapFromHBITMAP(hbm: HBITMAP; hpal: HPALETTE; out bitmap: GpBitmap): GpStatus;
stdcall; external 'gdiplus.dll';
function GdipDisposeImage(image: GpImage): GpStatus;
stdcall; external 'gdiplus.dll';
function GdipSetInterpolationMode(graphics: GpGraphics; interpolationMode: Integer): GpStatus;
stdcall; external 'gdiplus.dll';
function GdipSetPixelOffsetMode(graphics: GpGraphics; pixelOffsetMode: Integer): GpStatus;
stdcall; external 'gdiplus.dll';
function GdipDrawImageRectI(graphics: GpGraphics; image: GpImage; x, y, width, height: Integer): GpStatus;
stdcall; external 'gdiplus.dll';
function GdipCreateBitmapFromScan0(width, height, stride, format: Integer; scan0: PByte; out bitmap: GpBitmap): GpStatus;
stdcall; external 'gdiplus.dll';
const
  InterpolationModeHighQualityBicubic = 7;
  PixelOffsetModeHalf                 = 2;   // sample pixel centres -> no half-texel edge shift
  PixelFormat32bppARGB                = $0026200A;  // GDI+ 32bpp, non-premultiplied; bytes B,G,R,A

var
  GGdiplusToken: ULONG_PTR = 0;
  GGdiplusOK: Boolean = False;

// Blit Src into rectangle R of Dest, scaled with the best available quality:
// GDI+ high-quality bicubic when available, else GDI HALFTONE (still better than
// the default COLORONCOLOR). Shared by every raster image draw path.
procedure DrawBitmapScaled(Dest: TBitmap; const R: TRect; Src: TBitmap);
var
  g: GpGraphics;
  img: GpBitmap;
  dw, dh, oldMode: Integer;
begin
  dw := R.Right - R.Left;
  dh := R.Bottom - R.Top;
  if (dw <= 0) or (dh <= 0) or (Src.Width <= 0) or (Src.Height <= 0) then Exit;

  if GGdiplusOK then
  begin
    img := nil;
    if (GdipCreateBitmapFromHBITMAP(Src.Handle, 0, img) = 0) and (img <> nil) then
    begin
      g := nil;
      if GdipCreateFromHDC(Dest.Canvas.Handle, g) = 0 then
      begin
        GdipSetInterpolationMode(g, InterpolationModeHighQualityBicubic);
        GdipSetPixelOffsetMode(g, PixelOffsetModeHalf);
        GdipDrawImageRectI(g, img, R.Left, R.Top, dw, dh);
        GdipDeleteGraphics(g);
        GdipDisposeImage(img);
        Exit;
      end;
      GdipDisposeImage(img);
    end;
  end;

  // GDI fallback: HALFTONE averages source pixels (good downscaling); requires a
  // brush-origin reset per MSDN to avoid a colour shift.
  oldMode := SetStretchBltMode(Dest.Canvas.Handle, HALFTONE);
  SetBrushOrgEx(Dest.Canvas.Handle, 0, 0, nil);
  Dest.Canvas.StretchDraw(R, Src);
  SetStretchBltMode(Dest.Canvas.Handle, oldMode);
end;

constructor TPdfBitmapRenderer.Create;
begin
  inherited Create;
  FOptions := DefaultOptions;
end;

destructor TPdfBitmapRenderer.Destroy;
var I: Integer;
begin
  for I := 0 to High(FLoadedFonts) do
    if FLoadedFonts[I].GDIHandle <> nil then
      RemoveFontMemResourceEx(FLoadedFonts[I].GDIHandle);
  inherited Destroy;
end;

// Read big-endian 16-bit word from a byte array.
function TTWord(const D: TPdfBytes; Off: Integer): Word;
inline;
begin
  Result := (D[Off] shl 8) or D[Off + 1];
end;

// Read big-endian 32-bit dword from a byte array.
function TTDWord(const D: TPdfBytes; Off: Integer): Cardinal;
inline;
begin
  Result := (Cardinal(D[Off]) shl 24) or (Cardinal(D[Off+1]) shl 16)
          or (Cardinal(D[Off+2]) shl 8) or D[Off+3];
end;

// Convert a UTF-16BE string inside the TrueType byte array to an AnsiString.
// Font family names are ASCII so this is safe.
function TTUtf16BE(const D: TPdfBytes; Off, Len: Integer): string;
var I: Integer;
begin
  SetLength(Result, Len div 2);
  for I := 0 to Len div 2 - 1 do
  begin
    // High byte is almost always 0 for Latin family names; just take low byte.
    Result[I + 1] := Chr(D[Off + I * 2 + 1]);
  end;
end;

// True if the font has a Windows (platform 3) cmap subtable. GDI renders Unicode
// text only through a (3,x) cmap; a font whose only cmap is Mac (platform 1) —
// common in LibreOffice TrueType subsets — loads but draws NOTHING via TextOut, so
// we must substitute instead. (head/glyf etc. are otherwise a normal TrueType.)
function HasWindowsCmap(const Data: TPdfBytes): Boolean;
var NumTables, I, NSub, S: Integer;
  TableOff, CmapOff: Cardinal;
  Tag: string;
  Plat: Word;
begin
  Result := False;
  if Length(Data) < 12 then Exit;
  NumTables := TTWord(Data, 4);
  CmapOff := 0;
  for I := 0 to NumTables - 1 do
  begin
    TableOff := 12 + Cardinal(I) * 16;
    if TableOff + 16 > Cardinal(Length(Data)) then Exit;
    Tag := Chr(Data[TableOff]) + Chr(Data[TableOff+1]) + Chr(Data[TableOff+2]) + Chr(Data[TableOff+3]);
    if Tag = 'cmap' then begin
      CmapOff := TTDWord(Data, TableOff + 8);
      Break;
    end;
  end;
  if (CmapOff = 0) or (CmapOff + 4 > Cardinal(Length(Data))) then Exit;
  NSub := TTWord(Data, CmapOff + 2);
  for S := 0 to NSub - 1 do
  begin
    if CmapOff + 4 + Cardinal(S)*8 + 8 > Cardinal(Length(Data)) then Break;
    Plat := TTWord(Data, CmapOff + 4 + S*8);
    if Plat = 3 then Exit(True);
  end;
end;

// Parse the TrueType 'name' table to extract nameID 1 (Family) and 2 (Subfamily).
// Returns False if the data is too short or malformed.
function ParseTTNames(const Data: TPdfBytes;
                      out Family: string; out Subfamily: string): Boolean;
var
  NumTables, I, Count, StrArea: Integer;
  TableOff, NameOff: Cardinal;
  Tag: string;
  PlatID, EncID, NameID, SLen, SOff: Word;
  WinFam, WinSub, MacFam, MacSub: string;
begin
  Result := False;
  Family := '';
  Subfamily := '';
  if Length(Data) < 12 then Exit;

  NumTables := TTWord(Data, 4);
  NameOff := 0;

  for I := 0 to NumTables - 1 do
  begin
    TableOff := 12 + Cardinal(I) * 16;
    if TableOff + 16 > Cardinal(Length(Data)) then Break;
    Tag := Chr(Data[TableOff]) + Chr(Data[TableOff+1])
         + Chr(Data[TableOff+2]) + Chr(Data[TableOff+3]);
    if Tag = 'name' then
    begin
      NameOff := TTDWord(Data, TableOff + 8);
      Break;
    end;
  end;

  if (NameOff = 0) or (NameOff + 6 > Cardinal(Length(Data))) then Exit;

  Count   := TTWord(Data, NameOff + 2);
  StrArea := TTWord(Data, NameOff + 4);

  WinFam := '';
  WinSub := '';
  MacFam := '';
  MacSub := '';

  for I := 0 to Count - 1 do
  begin
    if NameOff + 6 + Cardinal(I) * 12 + 12 > Cardinal(Length(Data)) then Break;
    PlatID := TTWord(Data, NameOff + 6 + I * 12);
    EncID  := TTWord(Data, NameOff + 6 + I * 12 + 2);
    NameID := TTWord(Data, NameOff + 6 + I * 12 + 6);
    SLen   := TTWord(Data, NameOff + 6 + I * 12 + 8);
    SOff   := TTWord(Data, NameOff + 6 + I * 12 + 10);

    if not (NameID in [1, 2]) then Continue;
    if NameOff + StrArea + SOff + SLen > Cardinal(Length(Data)) then Continue;

    if (PlatID = 3) and (EncID = 1) then
    begin
      // Windows Unicode UTF-16BE — preferred
      if NameID = 1 then WinFam := TTUtf16BE(Data, NameOff + StrArea + SOff, SLen)
      else               WinSub := TTUtf16BE(Data, NameOff + StrArea + SOff, SLen);
    end
    else if (PlatID = 1) and (EncID = 0) then
    begin
      // Mac Roman — fallback
      if (NameID = 1) and (MacFam = '') then
      begin
        SetLength(MacFam, SLen);
        Move(Data[NameOff + StrArea + SOff], MacFam[1], SLen);
      end
      else if (NameID = 2) and (MacSub = '') then
      begin
        SetLength(MacSub, SLen);
        Move(Data[NameOff + StrArea + SOff], MacSub[1], SLen);
      end;
    end;
  end;

  if WinFam <> '' then begin
    Family := WinFam;
    Subfamily := WinSub;
  end
  else                   begin
    Family := MacFam;
    Subfamily := MacSub;
  end;
  Result := Family <> '';
end;

// Load a TrueType font into GDI from raw bytes. Returns the index into
// FLoadedFonts (>= 0) on success, -1 on failure. Caches by BaseFont name.
function TPdfBitmapRenderer.LoadTTFont(const BaseFont: string;
                                       const Data: TPdfBytes): Integer;
var
  Entry: TLoadedFontEntry;
  NumFonts: LongWord;
  I: Integer;
  IsCFF: Boolean;
  LoadData: TPdfBytes;
  Fam: string;
  Sig: LongWord;
begin
  // Signature of the embedded program: distinct font subsets often SHARE a BaseFont
  // name (e.g. many "ArialMT-Identity-H" CID subsets), so the cache must key on the
  // actual bytes, not just the name — otherwise every run reuses the first subset's
  // glyphs/charset and renders the wrong text.
  Sig := LongWord(Length(Data));
  for I := 0 to High(Data) do Sig := Sig * 31 + Data[I];

  // Return cached entry if already loaded.
  for I := 0 to High(FLoadedFonts) do
    if (FLoadedFonts[I].BaseFont = BaseFont) and (FLoadedFonts[I].ProgSig = Sig) then Exit(I);

  Result := -1;
  if Length(Data) = 0 then Exit;

  Entry.BaseFont  := BaseFont;
  Entry.ProgSig   := Sig;
  Entry.GDIHandle := nil;
  Entry.FamilyName := '';
  Entry.Subfamily  := '';
  SetLength(Entry.CidToGid, 0);

  // A bare CFF (Type1C) starts with version byte 1; TrueType/OpenType begins
  // with 0x00010000 / 'OTTO' / 'true'. GDI can't load bare CFF, so wrap it in an
  // OTF first and select it by a unique synthesized family name.
  IsCFF := (Length(Data) >= 4) and (Data[0] = 1) and (Data[1] = 0) and
           (Data[2] >= 4) and (Data[2] <= 8);
  if IsCFF then
  begin
    Fam := 'PdfCFF' + IntToStr(Length(FLoadedFonts));
    LoadData := WrapCFFToOTF(Data, AnsiString(Fam));
    if Length(LoadData) = 0 then Exit;  // wrap failed -> caller substitutes
    Entry.FamilyName := Fam;  // embedded outlines carry their own weight
    Entry.Subfamily  := '';  // so no synthetic bold/italic
    // CID-keyed CFF: the content stream's CIDs are not the GIDs — capture the
    // charset's CID->GID map so the renderer can draw by glyph index.
    Entry.CidToGid := CFFCidToGid(Data);
  end
  else
  begin
    // The parser (BuildFontMap) already injects a Windows (3,1) cmap into embedded
    // TrueType subsets that lack one (composing the PDF's code->Unicode with the
    // font's code->GID). If a Windows cmap is still missing here, GDI's Unicode
    // TextOut would draw nothing, so refuse and let the caller substitute.
    if not HasWindowsCmap(Data) then Exit;
    LoadData := Data;
  end;

  // Windows GDI's AddFontMemResourceEx only accepts sfntVersion 0x00010000; it
  // REJECTS Apple's 'true' (0x74727565) tag, which LibreOffice emits for embedded
  // TrueType subsets (e.g. BAAAAA+LiberationSerif in some PDFs). Patch the version
  // so the embedded font loads instead of falling back to a substitute. Copy first
  // so the caller's FontProgram bytes aren't mutated. (GDI ignores the head
  // checkSumAdjustment, so no recompute is needed — verified.)
  if (not IsCFF) and (Length(LoadData) >= 4) and
     (LoadData[0] = $74) and (LoadData[1] = $72) and
     (LoadData[2] = $75) and (LoadData[3] = $65) then
  begin
    LoadData := Copy(LoadData);
    LoadData[0] := $00;
    LoadData[1] := $01;
    LoadData[2] := $00;
    LoadData[3] := $00;
  end;

  NumFonts := 0;
  Entry.GDIHandle := AddFontMemResourceEx(@LoadData[0], LongWord(Length(LoadData)),
                                          nil, @NumFonts);
  if Entry.GDIHandle = nil then Exit;

  if not IsCFF then
    ParseTTNames(LoadData, Entry.FamilyName, Entry.Subfamily);

  Result := Length(FLoadedFonts);
  SetLength(FLoadedFonts, Result + 1);
  FLoadedFonts[Result] := Entry;
end;

class function TPdfBitmapRenderer.DefaultOptions: TPdfBitmapRenderOptions;
begin
  Result.Scale := 1.0;
  Result.BackgroundColor := clWhite;
  Result.TextColor := clBlack;
  Result.StrokeColor := clBlack;
  Result.ImagePlaceholderColor := clSilver;
  Result.DrawImagePlaceholders := True;
  Result.DrawUnknownPlaceholders := False;
  Result.AntialiasVectors := True;
end;

function TPdfBitmapRenderer.PageToBitmapX(const Page: TPdfPage; X: Double): Integer;
begin
  Result := Round((X - Page.CropBox.X1) * FOptions.Scale);
end;

function TPdfBitmapRenderer.PageToBitmapY(const Page: TPdfPage; Y: Double): Integer;
begin
  // PDF origin is bottom-left, TBitmap canvas origin is top-left.
  Result := Round((Page.CropBox.Y2 - Y) * FOptions.Scale);
end;

function TPdfBitmapRenderer.MatrixScaleX(const M: TPdfMatrix): Double;
begin
  Result := Sqrt(M.A * M.A + M.B * M.B);
  if Result = 0 then Result := 1;
end;

function TPdfBitmapRenderer.MatrixScaleY(const M: TPdfMatrix): Double;
begin
  Result := Sqrt(M.C * M.C + M.D * M.D);
  if Result = 0 then Result := 1;
end;

// Map a PDF BaseFont name to a Windows font family name and style flags.
procedure ParsePdfBaseFont(const BaseFont: string;
                           out Family: string; out Style: TFontStyles);
var N: string;
begin
  Style := [];
  N := BaseFont;
  // Strip subset tag: 6 uppercase letters followed by '+'
  if (Length(N) > 7) and (N[7] = '+') then
    N := Copy(N, 8, MaxInt);
  // Bold / italic detection from suffix patterns (Black/Heavy are heavy weights too)
  if ContainsText(N, 'Bold') or ContainsText(N, 'Black') or ContainsText(N, 'Blac') or
     ContainsText(N, 'Heavy') then Include(Style, fsBold);
  if ContainsText(N, 'Italic') or ContainsText(N, 'Oblique') then Include(Style, fsItalic);
  // Comma-separated style suffix used by some PDF producers (e.g. "Arial,Bold")
  if Pos(',', N) > 0 then N := Copy(N, 1, Pos(',', N) - 1);
  // Condensed faces — note before family mapping so we can pick a narrow Windows font.
  // Map PostScript / PDF family names to the closest commonly-installed Windows font.
  if ContainsText(N, 'TimesNewRoman') or ContainsText(N, 'Times New Roman') then
    Family := 'Times New Roman'
  else if ContainsText(N, 'NimbusRoman') or ContainsText(N, 'Times') then
    Family := 'Times New Roman'
  // Minion / Garamond / Palatino-ish serif text faces
  else if ContainsText(N, 'MinionPro') or ContainsText(N, 'Minion') then
    Family := 'Georgia'
  else if ContainsText(N, 'Palatino') then
    Family := 'Palatino Linotype'
  else if ContainsText(N, 'Garamond') then
    Family := 'Garamond'
  else if ContainsText(N, 'Georgia') then
    Family := 'Georgia'
  // Futura — geometric sans; Century Gothic is the closest Windows match.
  else if ContainsText(N, 'FuturaCond') or ContainsText(N, 'Futura-Cond') or
          (ContainsText(N, 'Futura') and ContainsText(N, 'Cond')) then
    Family := 'Arial Narrow'   // condensed display sans — use a narrow Windows face
  else if ContainsText(N, 'Futura') then
    Family := 'Century Gothic'
  // Oliwka — a narrow heavy Polish display sans (no Windows equivalent)
  else if ContainsText(N, 'Oliwka') then
    Family := 'Arial Narrow'
  // Nimbus Sans / Helvetica / Humanist -> Arial family
  else if ContainsText(N, 'NimbusSans') or ContainsText(N, 'Helvetica') or
          ContainsText(N, 'Humanist') or ContainsText(N, 'Arial') or
          ContainsText(N, 'TTRationalist') then
    Family := 'Arial'
  // Cooper Black — heavy display serif
  else if ContainsText(N, 'Cooper') then
    Family := 'Cooper Black'
  // Scripts / handwriting
  else if ContainsText(N, 'Corsiva') or ContainsText(N, 'Chancery') then
    Family := 'Monotype Corsiva'
  else if ContainsText(N, 'FreestyleScript') or ContainsText(N, 'Script') or
          ContainsText(N, 'Brush') then
    Family := 'Segoe Script'
  // Monospace / code faces
  else if ContainsText(N, 'Consolas') or ContainsText(N, 'FiraMono') or
          ContainsText(N, 'Mono') or ContainsText(N, 'Courier') then
    Family := 'Consolas'
  else if ContainsText(N, 'Verdana') then
    Family := 'Verdana'
  else if ContainsText(N, 'Tahoma') then
    Family := 'Tahoma'
  else if ContainsText(N, 'Calibri') then
    Family := 'Calibri'
  else if ContainsText(N, 'Cambria') then
    Family := 'Cambria'
  // Generic family-class fallback for faces with no specific Windows match
  // (LiberationSerif, DejaVuSerif, NotoSerif, PTSerif, LiberationSans, …). A
  // "Serif" name must NOT render in Arial — map it to a serif Windows face.
  else if ContainsText(N, 'Serif') then
    Family := 'Times New Roman'
  else if ContainsText(N, 'Sans') then
    Family := 'Arial'
  else
    Family := N;
  // Any remaining condensed/narrow sans face maps to a narrow Windows font so it
  // doesn't render too wide (substitute fonts are otherwise much wider).
  if (ContainsText(N, 'Cond') or ContainsText(N, 'Narrow') or ContainsText(N, 'Compress')) and
     ((Family = 'Arial') or (Family = 'Tahoma') or (Family = 'Century Gothic') or
      (Family = 'Verdana') or (Family = 'Calibri') or (Family = N)) then
    Family := 'Arial Narrow';
  // Script faces are inherently slanted; render them italic so they match the
  // original slant (e.g. Freestyle Script "JetCopy" on the cover, which sits
  // over its own slanted artwork shadow).
  if (Family = 'Segoe Script') or (Family = 'Monotype Corsiva') then
    Include(Style, fsItalic);
end;

// Draw a run of glyph IDs (CID=GID) at device baseline (X,Y) using the font already
// selected into DC, with explicit per-glyph device advances from E.GlyphAdv (page
// space × Scale, accumulated to avoid rounding drift).
procedure TPdfBitmapRenderer.DrawGlyphRun(Bitmap: TBitmap; E: TPdfTextElement; X, Y, CacheIdx: Integer; DC: HDC);
const ETO_GI = $0010;   // ETO_GLYPH_INDEX
var
  n, i, prevMode, cid: Integer;
  gids: array of Word;
  dx: array of Integer;
  accPg: Double;
  accDev, dev: Integer;
  hasMap: Boolean;
begin
  n := Length(E.GlyphIDs);
  if n = 0 then Exit;
  hasMap := (CacheIdx >= 0) and (Length(FLoadedFonts[CacheIdx].CidToGid) > 0);
  SetLength(gids, n);
  SetLength(dx, n);
  accPg := 0; accDev := 0;
  for i := 0 to n - 1 do
  begin
    cid := E.GlyphIDs[i];
    // CID -> GID via the CFF charset (CID is NOT the GID for a subset CID-CFF).
    if hasMap and (cid < Length(FLoadedFonts[CacheIdx].CidToGid)) then
      gids[i] := FLoadedFonts[CacheIdx].CidToGid[cid]
    else
      gids[i] := Word(cid);
    accPg := accPg + E.GlyphAdv[i];
    dev := Round(accPg * FOptions.Scale);
    dx[i] := dev - accDev;       // device advance for this glyph (drift-corrected)
    accDev := dev;
  end;
  // Realize the LCL Canvas font into the raw DC. We draw with raw ExtTextOutW (not
  // a Canvas method), so LCL hasn't necessarily selected the current Font into the
  // DC — without this the DC keeps a previous element's HFONT and the glyph indices
  // are drawn from the WRONG font.
  SelectObject(DC, Bitmap.Canvas.Font.Reference.Handle);
  prevMode := SetTextAlign(DC, TA_LEFT or TA_BASELINE);
  SetBkMode(DC, TRANSPARENT);
  ExtTextOutW(DC, X, Y, ETO_GI, nil, PWideChar(@gids[0]), n, @dx[0]);
  SetTextAlign(DC, prevMode);
end;

procedure TPdfBitmapRenderer.DrawTextElement(Bitmap: TBitmap; Page: TPdfPage; E: TPdfTextElement);
var
  X, Y, SizePx, CacheIdx, IntendedW, NaturalW, DrawX, DrawY: Integer;
  S: UTF8String;
  Family, Subfamily: string;
  Style: TFontStyles;
  sx, L, ux, uy: Double;
  Xf: XFORM;
  UseXf, Rotated: Boolean;
  RMode, swpx: Integer;
  DC: HDC;
  hPen, hOldPen, hBrush, hOldBrush: HGDIOBJ;
begin
  X := PageToBitmapX(Page, E.Matrix.E);
  Y := PageToBitmapY(Page, E.Matrix.F);
  SizePx := Max(1, Round(E.FontSize * FOptions.Scale * MatrixScaleY(E.Matrix)));

  Bitmap.Canvas.Brush.Style := bsClear;
  // Use the element's non-stroking fill colour; fall back to the option default only
  // when the element colour is exactly default black (all three channels = 0).
  if (E.FillR > 0) or (E.FillG > 0) or (E.FillB > 0) then
    Bitmap.Canvas.Font.Color := RGBToColor(Round(E.FillR*255), Round(E.FillG*255), Round(E.FillB*255))
  else
    Bitmap.Canvas.Font.Color := FOptions.TextColor;
  // Font.Height (negative = character height in device pixels) bypasses the
  // screen-DPI conversion that Font.Size applies, giving correct bitmap pixels.
  Bitmap.Canvas.Font.Height := -SizePx;

  Style := [];
  if Length(E.FontProgram) > 0 then
  begin
    // Embedded TrueType: load into GDI and use the name from the font's own name table.
    CacheIdx := LoadTTFont(E.BaseFont, E.FontProgram);
    if CacheIdx >= 0 then
    begin
      Family    := FLoadedFonts[CacheIdx].FamilyName;
      Subfamily := FLoadedFonts[CacheIdx].Subfamily;
      if ContainsText(Subfamily, 'Bold')   then Include(Style, fsBold);
      if ContainsText(Subfamily, 'Italic') or ContainsText(Subfamily, 'Oblique') then
        Include(Style, fsItalic);
      Bitmap.Canvas.Font.Name  := Family;
      Bitmap.Canvas.Font.Style := Style;
    end
    else if E.BaseFont <> '' then
    begin
      ParsePdfBaseFont(E.BaseFont, Family, Style);
      Bitmap.Canvas.Font.Name  := Family;
      Bitmap.Canvas.Font.Style := Style;
    end;
  end
  else if E.BaseFont <> '' then
  begin
    ParsePdfBaseFont(E.BaseFont, Family, Style);
    Bitmap.Canvas.Font.Name  := Family;
    Bitmap.Canvas.Font.Style := Style;
  end;

  DC := Bitmap.Canvas.Handle;

  // Embedded CID/Type0 font: draw the real glyphs BY INDEX (CID=GID) using the
  // loaded program + PDF /W advances. This is the only way to render Identity-H
  // CID fonts with no ToUnicode (otherwise the decoded "text" is meaningless and
  // shows as .notdef boxes). Non-rotated runs only; rotated CID falls through.
  if (Length(E.GlyphIDs) > 0) and (Length(E.FontProgram) > 0) and (CacheIdx >= 0)
     and (Abs(E.Matrix.B) <= 1E-3) and (Abs(E.Matrix.C) <= 1E-3) then
  begin
    DrawGlyphRun(Bitmap, E, X, Y, CacheIdx, DC);
    Exit;
  end;

  S := UTF8Encode(E.Text);
  UseXf := False;

  // Rotated/skewed text: the text matrix has non-zero B/C (e.g. the vertical
  // "JetCopy" on page 20 or the side notice on page 9). GDI draws the string
  // through a world transform that rotates text space into device space, with
  // the baseline origin pinned at the PDF text origin (Matrix.E,Matrix.F).
  Rotated := (Abs(E.Matrix.B) > 1E-3) or (Abs(E.Matrix.C) > 1E-3);
  if Rotated then
  begin
    L := Sqrt(E.Matrix.A*E.Matrix.A + E.Matrix.B*E.Matrix.B);
    if L < 1E-9 then L := 1E-9;
    ux := E.Matrix.A / L;  // device advance direction (page Y is flipped,
    uy := -E.Matrix.B / L;  // so page +Y -> device -Y)
    // The font height is set from MatrixScaleY, so GDI advances glyphs at that
    // scale. Fit the advance axis so the baseline runs the PDF's true advance
    // length (E.AdvanceLen, page space). This corrects BOTH anamorphic matrices
    // (e.g. page-20 JetCopy [0 90 -72 0], advance scale 90 != height 72) AND the
    // small mismatch between GDI's embedded-font advances and the PDF /Widths —
    // so the rotated text matches its shadow (which is rasterized at /Widths).
    NaturalW := Bitmap.Canvas.TextWidth(string(S));
    if NaturalW > 0 then
      sx := (E.AdvanceLen * FOptions.Scale) / NaturalW
    else
      sx := L / MatrixScaleY(E.Matrix);
    if (sx <= 0.1) or (sx >= 5.0) then sx := L / MatrixScaleY(E.Matrix);  // sanity
    SetGraphicsMode(DC, GM_ADVANCED);
    FillChar(Xf, SizeOf(Xf), 0);
    Xf.eM11 := ux*sx;
    Xf.eM12 := uy*sx;  // logical +x (advance) -> (ux,uy)*ratio
    Xf.eM21 := -uy;
    Xf.eM22 := ux;  // logical +y (glyph-down) -> rot +90
    Xf.eDx := X;
    Xf.eDy := Y;  // baseline origin
    SetWorldTransform(DC, Xf);
    DrawX := 0;
    DrawY := 0;
    UseXf := True;
  end
  else
  begin
    // Horizontal width-fit: scale the glyph run toward the PDF's own advance width
    // (Bounds.X2-X1). SQUEEZING (sx<1) is always allowed — substitute faces are
    // often wider than the original. STRETCHING (sx>1) is allowed for anamorphic
    // matrices (cover headlines A=66 D=59) AND for single-word runs (no space char):
    // there the extra advance is real glyph advance, so fitting it exactly aligns
    // the run with fixed-position artwork — e.g. the cover "JetCopy", whose black
    // drop shadow is baked into the cover image and was wider than the live yellow
    // text. Stretching is suppressed only for MULTI-word, non-anamorphic lines,
    // where the surplus width is word/char spacing in JUSTIFIED text and stretching
    // glyphs to fill it would distort them (the space belongs between words).
    IntendedW := Round((E.Bounds.X2 - E.Bounds.X1) * FOptions.Scale);
    NaturalW  := Bitmap.Canvas.TextWidth(string(S));
    if (NaturalW > 0) and (IntendedW > 0) then
    begin
      sx := IntendedW / NaturalW;
      if (sx > 1.0) and (Pos(' ', string(S)) > 0) and
         (MatrixScaleX(E.Matrix) <= MatrixScaleY(E.Matrix) * 1.03) then
        sx := 1.0;  // justified multi-word, not anamorphic -> don't stretch
      if ((sx < 0.97) or (sx > 1.03)) and (sx > 0.1) and (sx < 5.0) then
      begin
        SetGraphicsMode(DC, GM_ADVANCED);
        FillChar(Xf, SizeOf(Xf), 0);
        Xf.eM11 := sx;
        Xf.eM12 := 0;
        Xf.eM21 := 0;
        Xf.eM22 := 1;
        Xf.eDx := X * (1 - sx);
        Xf.eDy := 0;
        SetWorldTransform(DC, Xf);
        UseXf := True;
      end;
    end;
    DrawX := X;
    DrawY := Y;  // PDF text origin is on the baseline
  end;

  // Draw all text from its baseline (the PDF text origin), not the cell top —
  // otherwise text sits ~0.2*size too high, which made the page-5 "STRZAŁKA"
  // fixed-position drop shadow look shifted far below the letters.
  SetTextAlign(DC, TA_LEFT or TA_BASELINE);

  // Text rendering mode (Tr): 0 fill, 1 stroke, 2 fill+stroke, 3 invisible
  // (4-7 add to the clip path — treated like 0-3 for painting). Stroke/fill+stroke
  // render the glyph as a GDI path so the outline can be stroked in the stroke
  // colour (e.g. the cover "5" = black stroked outline under a yellow fill).
  RMode := E.RenderMode and 3;
  if RMode = 3 then
    // invisible: paint nothing
  else if RMode = 0 then
    Bitmap.Canvas.TextOut(DrawX, DrawY, string(S))
  else
  begin
    BeginPath(DC);
    Bitmap.Canvas.TextOut(DrawX, DrawY, string(S));
    EndPath(DC);
    swpx := Max(1, Round(E.StrokeWidth * FOptions.Scale));
    hPen := CreatePen(PS_SOLID, swpx, RGB(
      EnsureRange(Round(E.StrokeR*255),0,255),
      EnsureRange(Round(E.StrokeG*255),0,255),
      EnsureRange(Round(E.StrokeB*255),0,255)));
    hOldPen := SelectObject(DC, hPen);
    if RMode = 2 then
    begin
      hBrush := CreateSolidBrush(RGB(
        EnsureRange(Round(E.FillR*255),0,255),
        EnsureRange(Round(E.FillG*255),0,255),
        EnsureRange(Round(E.FillB*255),0,255)));
      hOldBrush := SelectObject(DC, hBrush);
      StrokeAndFillPath(DC);
      SelectObject(DC, hOldBrush);
      DeleteObject(hBrush);
    end
    else
      StrokePath(DC);
    SelectObject(DC, hOldPen);
    DeleteObject(hPen);
  end;

  if UseXf then
  begin
    FillChar(Xf, SizeOf(Xf), 0);
    Xf.eM11 := 1;
    Xf.eM22 := 1;
    SetWorldTransform(DC, Xf);
    SetGraphicsMode(DC, GM_COMPATIBLE);
  end;
  SetTextAlign(DC, TA_LEFT or TA_TOP);  // restore default for other drawing
end;

// Composite an image that has per-pixel alpha (/SMask). Builds a 32bpp ARGB buffer
// (RGB from the image data per colour space, A from E.Alpha) and draws it scaled to
// R: GDI+ (bicubic, honours the alpha channel) when available, else GDI AlphaBlend
// with a premultiplied source. Transparent areas show the page through.
procedure TPdfBitmapRenderer.DrawImageAlpha(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
var
  W, H, x, y, i, idx, dw, dh: Integer;
  r8, g8, b8, a: Byte;
  CS: string;
  rgb: Boolean;
  buf: array of Byte;          // BGRA, non-premultiplied (for GDI+)
  img: GpBitmap;
  g: GpGraphics;
  Src: TBitmap;
  Dst: PByte;
  BF: TBlendFunction;
begin
  W := E.Width; H := E.Height;
  dw := R.Right - R.Left; dh := R.Bottom - R.Top;
  if (W <= 0) or (H <= 0) or (dw <= 0) or (dh <= 0) or (Length(E.Alpha) < W*H) then Exit;
  CS := E.ColorSpace;
  rgb := SameText(CS,'DeviceRGB') or SameText(CS,'CalRGB') or SameText(CS,'ICCBased') or (CS = '');

  SetLength(buf, W * H * 4);
  for y := 0 to H - 1 do
    for x := 0 to W - 1 do
    begin
      i := y*W + x;
      if rgb and (i*3 + 2 < Length(E.Data)) then
      begin r8 := E.Data[i*3]; g8 := E.Data[i*3+1]; b8 := E.Data[i*3+2]; end
      else if SameText(CS,'Indexed') and (i < Length(E.Data)) then
      begin
        idx := E.Data[i];
        if (idx*3 + 2 < Length(E.Palette)) then
        begin r8 := E.Palette[idx*3]; g8 := E.Palette[idx*3+1]; b8 := E.Palette[idx*3+2]; end
        else begin r8 := 0; g8 := 0; b8 := 0; end;
      end
      else if i < Length(E.Data) then begin r8 := E.Data[i]; g8 := r8; b8 := r8; end
      else begin r8 := 0; g8 := 0; b8 := 0; end;
      a := E.Alpha[i];
      buf[i*4+0] := b8;     // GDI+ 32bppARGB byte order is B,G,R,A
      buf[i*4+1] := g8;
      buf[i*4+2] := r8;
      buf[i*4+3] := a;
    end;

  if GGdiplusOK then
  begin
    img := nil;
    if (GdipCreateBitmapFromScan0(W, H, W*4, PixelFormat32bppARGB, @buf[0], img) = 0) and (img <> nil) then
    begin
      g := nil;
      if GdipCreateFromHDC(Bitmap.Canvas.Handle, g) = 0 then
      begin
        GdipSetInterpolationMode(g, InterpolationModeHighQualityBicubic);
        GdipSetPixelOffsetMode(g, PixelOffsetModeHalf);
        GdipDrawImageRectI(g, img, R.Left, R.Top, dw, dh);
        GdipDeleteGraphics(g);
        GdipDisposeImage(img);
        Exit;
      end;
      GdipDisposeImage(img);
    end;
  end;

  // GDI fallback: premultiplied BGRA + AlphaBlend.
  Src := TBitmap.Create;
  try
    Src.PixelFormat := pf32bit;
    Src.SetSize(W, H);
    for y := 0 to H - 1 do
    begin
      Dst := Src.ScanLine[y];
      for x := 0 to W - 1 do
      begin
        i := y*W + x; a := buf[i*4+3];
        Dst[x*4+0] := (buf[i*4+0] * a) div 255;
        Dst[x*4+1] := (buf[i*4+1] * a) div 255;
        Dst[x*4+2] := (buf[i*4+2] * a) div 255;
        Dst[x*4+3] := a;
      end;
    end;
    BF.BlendOp := AC_SRC_OVER; BF.BlendFlags := 0;
    BF.SourceConstantAlpha := 255; BF.AlphaFormat := AC_SRC_ALPHA;
    AlphaBlend(Bitmap.Canvas.Handle, R.Left, R.Top, dw, dh, Src.Canvas.Handle, 0, 0, W, H, BF);
  finally
    Src.Free;
  end;
end;

procedure TPdfBitmapRenderer.DrawRawDeviceGray(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
var
  TmpBmp: TBitmap;
  Y, X: Integer;
  Src: PByte;
  Dst: PByte;
  G: Byte;
begin
  if (E.Width <= 0) or (E.Height <= 0) or (Length(E.Data) < E.Width * E.Height) then
  begin
    DrawPlaceholder(Bitmap, R, E.Name);
    Exit;
  end;

  // Build a 24-bit TBitmap from the raw gray bytes, then let StretchDraw scale it.
  // This replaces ~90 k individual Canvas.Pixels GDI calls with a single blit.
  TmpBmp := TBitmap.Create;
  try
    TmpBmp.PixelFormat := pf24bit;
    TmpBmp.SetSize(E.Width, E.Height);
    for Y := 0 to E.Height - 1 do
    begin
      Src := @E.Data[Y * E.Width];
      Dst := TmpBmp.ScanLine[Y];
      for X := 0 to E.Width - 1 do
      begin
        G := Src[X];
        Dst[X * 3 + 0] := G;  // B
        Dst[X * 3 + 1] := G;  // G
        Dst[X * 3 + 2] := G;  // R
      end;
    end;
    DrawBitmapScaled(Bitmap, R, TmpBmp);
  finally
    TmpBmp.Free;
  end;
end;

procedure TPdfBitmapRenderer.DrawRawDeviceRGB(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
var
  TmpBmp: TBitmap;
  Y, X: Integer;
  Src: PByte;
  Dst: PByte;
begin
  if (E.Width <= 0) or (E.Height <= 0) or (Length(E.Data) < E.Width * E.Height * 3) then
  begin
    DrawPlaceholder(Bitmap, R, E.Name);
    Exit;
  end;

  // Build a 24-bit TBitmap from the raw RGB bytes, then let StretchDraw scale it.
  // PDF stores R,G,B; Windows scanlines are B,G,R — swap channels while copying.
  TmpBmp := TBitmap.Create;
  try
    TmpBmp.PixelFormat := pf24bit;
    TmpBmp.SetSize(E.Width, E.Height);
    for Y := 0 to E.Height - 1 do
    begin
      Src := @E.Data[Y * E.Width * 3];
      Dst := TmpBmp.ScanLine[Y];
      for X := 0 to E.Width - 1 do
      begin
        Dst[X * 3 + 0] := Src[X * 3 + 2];  // B ← R
        Dst[X * 3 + 1] := Src[X * 3 + 1];  // G
        Dst[X * 3 + 2] := Src[X * 3 + 0];  // R ← B
      end;
    end;
    DrawBitmapScaled(Bitmap, R, TmpBmp);
  finally
    TmpBmp.Free;
  end;
end;

procedure TPdfBitmapRenderer.DrawRawDeviceCMYK(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
var
  TmpBmp: TBitmap;
  Y, X, c, m, yy, k: Integer;
  Src, Dst: PByte;
begin
  if (E.Width <= 0) or (E.Height <= 0) or (Length(E.Data) < E.Width * E.Height * 4) then
  begin
    DrawPlaceholder(Bitmap, R, E.Name);
    Exit;
  end;
  // Raw DeviceCMYK (not Adobe-inverted): R = (1-C)(1-K), etc.
  TmpBmp := TBitmap.Create;
  try
    TmpBmp.PixelFormat := pf24bit;
    TmpBmp.SetSize(E.Width, E.Height);
    for Y := 0 to E.Height - 1 do
    begin
      Src := @E.Data[Y * E.Width * 4];
      Dst := TmpBmp.ScanLine[Y];
      for X := 0 to E.Width - 1 do
      begin
        c := Src[X*4+0];
        m := Src[X*4+1];
        yy := Src[X*4+2];
        k := Src[X*4+3];
        Dst[X*3+0] := Byte((255 - yy) * (255 - k) div 255);  // B
        Dst[X*3+1] := Byte((255 - m)  * (255 - k) div 255);  // G
        Dst[X*3+2] := Byte((255 - c)  * (255 - k) div 255);  // R
      end;
    end;
    DrawBitmapScaled(Bitmap, R, TmpBmp);
  finally
    TmpBmp.Free;
  end;
end;

procedure TPdfBitmapRenderer.DrawIndexedImage(Bitmap: TBitmap; const R: TRect; E: TPdfImageElement);
var
  TmpBmp: TBitmap;
  Y, X, Bpc, Stride, Idx, BitPos, BytePos, Shift, Mask: Integer;
  Dst: PByte;
  RowBase: Integer;
begin
  Bpc := E.BitsPerComponent;
  if Bpc <= 0 then Bpc := 8;
  Stride := (E.Width * Bpc + 7) div 8;
  if (E.Width <= 0) or (E.Height <= 0) or (E.PaletteCount <= 0) or
     (Length(E.Palette) < E.PaletteCount * 3) or (Length(E.Data) < Stride * E.Height) then
  begin
    DrawPlaceholder(Bitmap, R, E.Name);
    Exit;
  end;
  Mask := (1 shl Bpc) - 1;
  TmpBmp := TBitmap.Create;
  try
    TmpBmp.PixelFormat := pf24bit;
    TmpBmp.SetSize(E.Width, E.Height);
    for Y := 0 to E.Height - 1 do
    begin
      Dst := TmpBmp.ScanLine[Y];
      RowBase := Y * Stride;
      for X := 0 to E.Width - 1 do
      begin
        if Bpc = 8 then
          Idx := E.Data[RowBase + X]
        else
        begin
          BitPos := X * Bpc;
          BytePos := RowBase + (BitPos div 8);
          Shift := 8 - Bpc - (BitPos mod 8);
          Idx := (E.Data[BytePos] shr Shift) and Mask;
        end;
        if Idx >= E.PaletteCount then Idx := E.PaletteCount - 1;
        Dst[X*3+0] := E.Palette[Idx*3+2];  // B
        Dst[X*3+1] := E.Palette[Idx*3+1];  // G
        Dst[X*3+2] := E.Palette[Idx*3+0];  // R
      end;
    end;
    DrawBitmapScaled(Bitmap, R, TmpBmp);
  finally
    TmpBmp.Free;
  end;
end;

// Draw a vector path with GDI+ antialiasing. Returns False if GDI+ is
// unavailable or fails, so the caller falls back to the plain-GDI path code.
function TPdfBitmapRenderer.DrawPathGdiPlus(Bitmap: TBitmap; Page: TPdfPage; E: TPdfPathElement): Boolean;
var
  g: GpGraphics;
  path: GpPath;
  brush: GpBrush;
  pen: GpPen;
  I, J, N: Integer;
  Pts: array of TGpPointF;
  col: ARGB;
  sc, cropX1, cropY2: Double;
begin
  Result := False;
  if (not GGdiplusOK) or (not FOptions.AntialiasVectors) then Exit;
  if Length(E.SubPaths) = 0 then Exit;
  if GdipCreateFromHDC(Bitmap.Canvas.Handle, g) <> 0 then Exit;
  sc := FOptions.Scale;
  cropX1 := Page.CropBox.X1;
  cropY2 := Page.CropBox.Y2;
  try
    GdipSetSmoothingMode(g, SmoothingModeAntiAlias);

    if E.DoFill then
      if GdipCreatePath(0, path) = 0 then
      begin
        if E.EvenOdd then GdipSetPathFillMode(path, FillModeAlternate)
        else              GdipSetPathFillMode(path, FillModeWinding);
        for I := 0 to High(E.SubPaths) do
        begin
          N := E.SubPaths[I].Count;
          if N < 3 then Continue;
          SetLength(Pts, N);
          for J := 0 to N-1 do
          begin
            Pts[J].X := (E.Points[E.SubPaths[I].StartIdx+J].X - cropX1) * sc;
            Pts[J].Y := (cropY2 - E.Points[E.SubPaths[I].StartIdx+J].Y) * sc;
          end;
          GdipStartPathFigure(path);
          GdipAddPathLine2(path, Pts[0], N);
          GdipClosePathFigure(path);
        end;
        col := $FF000000 or (LongWord(EnsureRange(Round(E.FillR*255),0,255)) shl 16)
                         or (LongWord(EnsureRange(Round(E.FillG*255),0,255)) shl 8)
                         or  LongWord(EnsureRange(Round(E.FillB*255),0,255));
        if GdipCreateSolidFill(col, brush) = 0 then
        begin
          GdipFillPath(g, brush, path);
          GdipDeleteBrush(brush);
        end;
        GdipDeletePath(path);
      end;

    if E.DoStroke then
      if GdipCreatePath(0, path) = 0 then
      begin
        for I := 0 to High(E.SubPaths) do
        begin
          N := E.SubPaths[I].Count;
          if N < 2 then Continue;
          SetLength(Pts, N);
          for J := 0 to N-1 do
          begin
            Pts[J].X := (E.Points[E.SubPaths[I].StartIdx+J].X - cropX1) * sc;
            Pts[J].Y := (cropY2 - E.Points[E.SubPaths[I].StartIdx+J].Y) * sc;
          end;
          GdipStartPathFigure(path);
          GdipAddPathLine2(path, Pts[0], N);
          if E.SubPaths[I].Closed then GdipClosePathFigure(path);
        end;
        col := $FF000000 or (LongWord(EnsureRange(Round(E.StrokeR*255),0,255)) shl 16)
                         or (LongWord(EnsureRange(Round(E.StrokeG*255),0,255)) shl 8)
                         or  LongWord(EnsureRange(Round(E.StrokeB*255),0,255));
        if GdipCreatePen1(col, Max(1.0, E.LineWidth*sc), UnitPixel, pen) = 0 then
        begin
          GdipSetPenLineJoin(pen, LineJoinRound);
          GdipDrawPath(g, pen, path);
          GdipDeletePen(pen);
        end;
        GdipDeletePath(path);
      end;

    Result := True;
  finally
    GdipDeleteGraphics(g);  // flushes the GDI+ output to the DC
  end;
end;

// Render the element's non-rectangular clip path(s) into Mask as an ANTIALIASED
// coverage (white = inside, black = outside, soft edges), with device coords
// shifted by (-OffX,-OffY). Mask must already be filled black. Used so a shading
// clipped to a glyph shape (the white-yellow ATARI) gets smooth glyph edges
// instead of the binary GDI clip region. Returns False if GDI+ is unavailable.
function TPdfBitmapRenderer.BuildClipCoverage(Mask: TBitmap; Page: TPdfPage; E: TPdfPageElement; OffX, OffY: Integer): Boolean;
var
  g: GpGraphics;
  brush: GpBrush;
  path: GpPath;
  K, I, J, N: Integer;
  CP: TPdfClipPath;
  Pts: array of TGpPointF;
  sc, cropX1, cropY2: Double;
  function MakePath(C: TPdfClipPath): GpPath;
  var ii, jj, nn: Integer;
  begin
    Result := nil;
    if GdipCreatePath(0, Result) <> 0 then Exit;
    if C.EvenOdd then GdipSetPathFillMode(Result, FillModeAlternate)
    else              GdipSetPathFillMode(Result, FillModeWinding);
    for ii := 0 to High(C.SubPaths) do
    begin
      nn := C.SubPaths[ii].Count;
      if nn < 3 then Continue;
      SetLength(Pts, nn);
      for jj := 0 to nn-1 do
      begin
        Pts[jj].X := (C.Points[C.SubPaths[ii].StartIdx+jj].X - cropX1) * sc - OffX;
        Pts[jj].Y := (cropY2 - C.Points[C.SubPaths[ii].StartIdx+jj].Y) * sc - OffY;
      end;
      GdipStartPathFigure(Result);
      GdipAddPathLine2(Result, Pts[0], nn);
      GdipClosePathFigure(Result);
    end;
  end;
begin
  Result := False;
  if (not GGdiplusOK) or (Length(E.ClipPaths) = 0) then Exit;
  if GdipCreateFromHDC(Mask.Canvas.Handle, g) <> 0 then Exit;
  sc := FOptions.Scale;
  cropX1 := Page.CropBox.X1;
  cropY2 := Page.CropBox.Y2;
  try
    GdipSetSmoothingMode(g, SmoothingModeAntiAlias);
    // Earlier clip paths become an (aliased) intersect clip; the LAST one — the
    // innermost, most-visible edge — is filled with antialiasing.
    for K := 0 to High(E.ClipPaths) - 1 do
    begin
      CP := TPdfClipPath(E.ClipPaths[K]);
      if (CP = nil) or (Length(CP.SubPaths) = 0) then Continue;
      path := MakePath(CP);
      if path <> nil then begin
        GdipSetClipPath(g, path, CombineModeIntersect);
        GdipDeletePath(path);
      end;
    end;
    CP := TPdfClipPath(E.ClipPaths[High(E.ClipPaths)]);
    if (CP = nil) or (Length(CP.SubPaths) = 0) then Exit;
    path := MakePath(CP);
    if path = nil then Exit;
    if GdipCreateSolidFill($FFFFFFFF, brush) = 0 then
    begin
      GdipFillPath(g, brush, path);
      GdipDeleteBrush(brush);
      Result := True;
    end;
    GdipDeletePath(path);
  finally
    GdipDeleteGraphics(g);
    GdiFlush;
  end;
end;

procedure TPdfBitmapRenderer.DrawPathElement(Bitmap: TBitmap; Page: TPdfPage; E: TPdfPathElement);
var
  I, J, N, Total, K: Integer;
  Sub: TPdfSubPath;
  AllPts: array of TPoint;
  Counts: array of Integer;
  DC: HDC;
  HBr, OldBrush, OldPen: HGDIOBJ;
  FillMode: Integer;
begin
  if Length(E.SubPaths) = 0 then Exit;

  // Preferred: antialiased GDI+ path. Falls back to plain GDI below on failure.
  if DrawPathGdiPlus(Bitmap, Page, E) then Exit;

  if E.DoFill then
  begin
    // Build the combined polygon set and let GDI fill it with the correct rule
    // (ALTERNATE = even-odd, WINDING = nonzero). This renders holes — letters,
    // frames, donut shapes — correctly across multiple subpaths.
    Total := 0;
    SetLength(Counts, 0);
    for I := 0 to High(E.SubPaths) do
      if E.SubPaths[I].Count >= 3 then Inc(Total, E.SubPaths[I].Count);
    if Total >= 3 then
    begin
      SetLength(AllPts, Total);
      K := 0;
      for I := 0 to High(E.SubPaths) do
      begin
        N := E.SubPaths[I].Count;
        if N < 3 then Continue;
        for J := 0 to N - 1 do
        begin
          AllPts[K].X := PageToBitmapX(Page, E.Points[E.SubPaths[I].StartIdx + J].X);
          AllPts[K].Y := PageToBitmapY(Page, E.Points[E.SubPaths[I].StartIdx + J].Y);
          Inc(K);
        end;
        SetLength(Counts, Length(Counts)+1);
        Counts[High(Counts)] := N;
      end;
      DC := Bitmap.Canvas.Handle;
      HBr := CreateSolidBrush(RGB(
        EnsureRange(Round(E.FillR*255), 0, 255),
        EnsureRange(Round(E.FillG*255), 0, 255),
        EnsureRange(Round(E.FillB*255), 0, 255)));
      OldBrush := SelectObject(DC, HBr);
      OldPen   := SelectObject(DC, GetStockObject(NULL_PEN));
      if E.EvenOdd then FillMode := ALTERNATE else FillMode := WINDING;
      SetPolyFillMode(DC, FillMode);
      Windows.PolyPolygon(DC, AllPts[0], Counts[0], Length(Counts));
      SelectObject(DC, OldPen);
      SelectObject(DC, OldBrush);
      DeleteObject(HBr);
    end;
  end;

  if E.DoStroke then
  begin
    Bitmap.Canvas.Pen.Color := RGBToColor(
      EnsureRange(Round(E.StrokeR*255), 0, 255),
      EnsureRange(Round(E.StrokeG*255), 0, 255),
      EnsureRange(Round(E.StrokeB*255), 0, 255));
    Bitmap.Canvas.Pen.Style := psSolid;
    Bitmap.Canvas.Pen.Width := Max(1, Round(E.LineWidth * FOptions.Scale));
    for I := 0 to High(E.SubPaths) do
    begin
      Sub := E.SubPaths[I];
      N := Sub.Count;
      if N < 2 then Continue;
      Bitmap.Canvas.MoveTo(PageToBitmapX(Page, E.Points[Sub.StartIdx].X),
                           PageToBitmapY(Page, E.Points[Sub.StartIdx].Y));
      for J := 1 to N - 1 do
        Bitmap.Canvas.LineTo(PageToBitmapX(Page, E.Points[Sub.StartIdx + J].X),
                             PageToBitmapY(Page, E.Points[Sub.StartIdx + J].Y));
      if Sub.Closed then
        Bitmap.Canvas.LineTo(PageToBitmapX(Page, E.Points[Sub.StartIdx].X),
                             PageToBitmapY(Page, E.Points[Sub.StartIdx].Y));
    end;
    Bitmap.Canvas.Pen.Width := 1;
  end;
end;

procedure TPdfBitmapRenderer.DrawShadingElement(Bitmap: TBitmap; Page: TPdfPage; E: TPdfShadingElement);
const NSTOPS = 256;
var
  LutR, LutG, LutB: array[0..NSTOPS-1] of Byte;
  I, px, py, L, T, Rr, Bt, BW, BH, idx, Wd, Hd: Integer;
  comps, tintOut: TDoubleArray;
  tval, det, sx, sy, s, pageX, pageY, ex, ey: Double;
  ax0, ay0, ax1, ay1, dx, dy, dlen2: Double;
  cx0, cy0, r0, cx1, cy1, r1, dcx, dcy, dr, qa, qb, qc, disc, sq, s1, s2: Double;
  M: TPdfMatrix;
  Src, ClipMask: TBitmap;
  SrcRow, CMRow: PByte;
  BF: TBlendFunction;
  rgR, rgG, rgB, av: Integer;
  Paint, HasClipMask: Boolean;
begin
  if not Assigned(E.Func) then Exit;
  if (E.ShadingType = 2) and (Length(E.Coords) < 4) then Exit;
  if (E.ShadingType = 3) and (Length(E.Coords) < 6) then Exit;

  // Precompute a colour lookup table along the gradient axis.
  for I := 0 to NSTOPS-1 do
  begin
    tval := E.Domain[0] + (I / (NSTOPS-1)) * (E.Domain[1] - E.Domain[0]);
    E.Func.Eval(tval, comps);
    // DeviceN/Separation: map colorant tints through the tint transform into the
    // alternate (device) colour space before the RGB conversion below.
    if Assigned(E.TintTransform) then
    begin
      E.TintTransform.EvalN(comps, tintOut);
      comps := tintOut;
    end;
    if Length(comps) = 1 then begin
      rgR := Round(comps[0]*255);
      rgG := rgR;
      rgB := rgR;
    end
    else if Length(comps) = 4 then
    begin
      rgR := Round((1-comps[0])*(1-comps[3])*255);
      rgG := Round((1-comps[1])*(1-comps[3])*255);
      rgB := Round((1-comps[2])*(1-comps[3])*255);
    end
    else if Length(comps) >= 3 then begin
      rgR := Round(comps[0]*255);
      rgG := Round(comps[1]*255);
      rgB := Round(comps[2]*255);
    end
    else begin
      rgR := 0;
      rgG := 0;
      rgB := 0;
    end;
    LutR[I] := EnsureRange(rgR,0,255);
    LutG[I] := EnsureRange(rgG,0,255);
    LutB[I] := EnsureRange(rgB,0,255);
  end;

  M := E.CTM;
  det := M.A*M.D - M.B*M.C;
  if Abs(det) < 1e-9 then Exit;

  BW := Bitmap.Width;
  BH := Bitmap.Height;
  // Pixel bounds: the element clip (rectangular) or the whole bitmap.
  if E.HasClip then
  begin
    L := PageToBitmapX(Page, E.Clip.X1);
    Rr := PageToBitmapX(Page, E.Clip.X2);
    T := PageToBitmapY(Page, E.Clip.Y2);
    Bt := PageToBitmapY(Page, E.Clip.Y1);
  end
  else begin
    L := 0;
    Rr := BW;
    T := 0;
    Bt := BH;
  end;
  if L > Rr then begin
    I := L;
    L := Rr;
    Rr := I;
  end;
  if T > Bt then begin
    I := T;
    T := Bt;
    Bt := I;
  end;
  L := Max(L, 0);
  T := Max(T, 0);
  Rr := Min(Rr, BW-1);
  Bt := Min(Bt, BH-1);

  ax0 := E.Coords[0];
  ay0 := E.Coords[1];
  if E.ShadingType = 2 then
  begin
    ax1 := E.Coords[2];
    ay1 := E.Coords[3];
    dx := ax1-ax0;
    dy := ay1-ay0;
    dlen2 := dx*dx + dy*dy;
    if dlen2 = 0 then dlen2 := 1e-9;
  end
  else
  begin
    cx0 := E.Coords[0];
    cy0 := E.Coords[1];
    r0 := E.Coords[2];
    cx1 := E.Coords[3];
    cy1 := E.Coords[4];
    r1 := E.Coords[5];
    dcx := cx1-cx0;
    dcy := cy1-cy0;
    dr := r1-r0;
  end;

  Wd := Rr - L + 1;
  Hd := Bt - T + 1;
  if (Wd <= 0) or (Hd <= 0) then Exit;
  // Render into an offscreen 32-bit buffer (alpha=255 where the gradient paints,
  // 0 elsewhere) then AlphaBlend onto the page. Direct ScanLine writes to the
  // page bitmap get discarded by later LCL Canvas drawing, so — like the
  // soft-mask path — the gradient must be composited through GDI.
  // If the shading is clipped to a non-rectangular shape (e.g. the white-yellow
  // ATARI gradient clipped to glyph outlines), render that clip as an ANTIALIASED
  // coverage mask and use it as the gradient's alpha — giving smooth glyph edges
  // instead of the binary GDI clip region. (The renderer skips the binary polygon
  // clip for such shadings so this soft edge isn't hard-clipped away.)
  ClipMask := nil;
  HasClipMask := False;
  if (Length(E.ClipPaths) > 0) and GGdiplusOK and FOptions.AntialiasVectors then
  begin
    ClipMask := TBitmap.Create;
    ClipMask.PixelFormat := pf24bit;
    ClipMask.SetSize(Wd, Hd);
    ClipMask.Canvas.Brush.Color := clBlack;
    ClipMask.Canvas.FillRect(0, 0, Wd, Hd);
    HasClipMask := BuildClipCoverage(ClipMask, Page, E, L, T);
  end;

  Src := TBitmap.Create;
  try
    Src.PixelFormat := pf32bit;
    Src.SetSize(Wd, Hd);
    for py := 0 to Hd-1 do
    begin
      SrcRow := Src.ScanLine[py];
      if HasClipMask then CMRow := ClipMask.ScanLine[py] else CMRow := nil;
      pageY := Page.CropBox.Y2 - (T + py) / FOptions.Scale;
      for px := 0 to Wd-1 do
      begin
        pageX := (L + px) / FOptions.Scale + Page.CropBox.X1;
      // Inverse CTM: page -> shading space.
      ex := pageX - M.E;
      ey := pageY - M.F;
      sx := (ex*M.D - ey*M.C) / det;
      sy := (-ex*M.B + ey*M.A) / det;

      Paint := True;
      s := 0;
      if E.ShadingType = 2 then
      begin
        s := ((sx-ax0)*dx + (sy-ay0)*dy) / dlen2;
        if s < 0 then begin
          if E.ExtendStart then s := 0 else Paint := False;
        end
        else if s > 1 then begin
          if E.ExtendEnd then s := 1 else Paint := False;
        end;
      end
      else
      begin
        // Radial: solve |P - C(s)| = R(s) for the largest valid s.
        qa := dcx*dcx + dcy*dcy - dr*dr;
        qb := 2*((sx-cx0)*(-dcx) + (sy-cy0)*(-dcy) - r0*dr);
        qc := (sx-cx0)*(sx-cx0) + (sy-cy0)*(sy-cy0) - r0*r0;
        Paint := False;
        if Abs(qa) < 1e-9 then
        begin
          if Abs(qb) > 1e-9 then begin
            s := -qc/qb;
            Paint := (r0 + s*dr) >= 0;
          end;
        end
        else
        begin
          disc := qb*qb - 4*qa*qc;
          if disc >= 0 then
          begin
            sq := Sqrt(disc);
            s1 := (-qb + sq)/(2*qa);
            s2 := (-qb - sq)/(2*qa);
            if s1 < s2 then begin
              tval := s1;
              s1 := s2;
              s2 := tval;
            end;
            if (r0 + s1*dr >= 0) then begin
              s := s1;
              Paint := True;
            end
            else if (r0 + s2*dr >= 0) then begin
              s := s2;
              Paint := True;
            end;
          end;
        end;
        if Paint then
        begin
          if s < 0 then begin
            if E.ExtendStart then s := 0 else Paint := False;
          end
          else if s > 1 then begin
            if E.ExtendEnd then s := 1 else Paint := False;
          end;
        end;
      end;

      if Paint then
      begin
        idx := Round(s * (NSTOPS-1));
        idx := EnsureRange(idx, 0, NSTOPS-1);
        if HasClipMask then av := CMRow[px*3] else av := 255;  // AA clip coverage
        // Premultiplied BGRA for AC_SRC_ALPHA.
        SrcRow[px*4+0] := (LutB[idx]*av) div 255;
        SrcRow[px*4+1] := (LutG[idx]*av) div 255;
        SrcRow[px*4+2] := (LutR[idx]*av) div 255;
        SrcRow[px*4+3] := av;
      end
      else
      begin
        SrcRow[px*4+0] := 0;
        SrcRow[px*4+1] := 0;
        SrcRow[px*4+2] := 0;
        SrcRow[px*4+3] := 0;
      end;
      end;
    end;
    BF.BlendOp := AC_SRC_OVER;
    BF.BlendFlags := 0;
    BF.SourceConstantAlpha := 255;
    BF.AlphaFormat := AC_SRC_ALPHA;
    AlphaBlend(Bitmap.Canvas.Handle, L, T, Wd, Hd, Src.Canvas.Handle, 0, 0, Wd, Hd, BF);
  finally
    Src.Free;
    ClipMask.Free;
  end;
end;

procedure TPdfBitmapRenderer.DrawPlaceholder(Bitmap: TBitmap; const R: TRect; const Caption: string);
begin
  if not FOptions.DrawImagePlaceholders then Exit;
  Bitmap.Canvas.Brush.Color := FOptions.ImagePlaceholderColor;
  Bitmap.Canvas.Pen.Color := FOptions.StrokeColor;
  Bitmap.Canvas.Rectangle(R);
  Bitmap.Canvas.Brush.Style := bsClear;
  Bitmap.Canvas.Font.Color := FOptions.StrokeColor;
  Bitmap.Canvas.TextOut(R.Left + 3, R.Top + 3, Caption);
end;

procedure TPdfBitmapRenderer.DrawJpegImage(Bitmap: TBitmap; const R: TRect;
  E: TPdfImageElement);
var
  MS: TMemoryStream;
  JpegImg: TJPEGImage;
  TmpBmp: TBitmap;
  W, H, X, Y: Integer;
  RGB: TPdfBytes;
  Dst: PByte;
begin
  // Decode with our own jpeglib-based path first. It applies a correct,
  // Adobe-aware CMYK -> RGB conversion; the stock LCL/TJPEGImage reader turns
  // DeviceCMYK images into colour negatives.
  if DecodeJpegToRGB(E.Data, W, H, RGB) and (W > 0) and (H > 0) then
  begin
    TmpBmp := TBitmap.Create;
    try
      TmpBmp.PixelFormat := pf24bit;
      TmpBmp.SetSize(W, H);
      for Y := 0 to H - 1 do
      begin
        Dst := TmpBmp.ScanLine[Y];
        for X := 0 to W - 1 do
        begin
          Dst[X*3 + 0] := RGB[(Y*W + X)*3 + 2];  // B
          Dst[X*3 + 1] := RGB[(Y*W + X)*3 + 1];  // G
          Dst[X*3 + 2] := RGB[(Y*W + X)*3 + 0];  // R
        end;
      end;
      DrawBitmapScaled(Bitmap, R, TmpBmp);
    finally
      TmpBmp.Free;
    end;
    Exit;
  end;

  // Fallback: let the LCL reader try (handles odd JPEGs our path may reject).
  MS := TMemoryStream.Create;
  JpegImg := TJPEGImage.Create;
  TmpBmp := TBitmap.Create;
  try
    MS.WriteBuffer(E.Data[0], Length(E.Data));
    MS.Position := 0;
    JpegImg.LoadFromStream(MS);
    TmpBmp.Assign(JpegImg);
    DrawBitmapScaled(Bitmap, R, TmpBmp);
  except
    DrawPlaceholder(Bitmap, R, E.Name);
  end;
  TmpBmp.Free;
  JpegImg.Free;
  MS.Free;
end;

procedure TPdfBitmapRenderer.DrawImageElement(Bitmap: TBitmap; Page: TPdfPage;
  E: TPdfImageElement);
var
  M: TPdfMatrix;
  BX, BY: array[0..3] of Integer;
  R: TRect;
  CS: string;
begin
  if Length(E.Data) = 0 then Exit;

  // Transform all 4 corners of the PDF unit square through the CTM.
  // This handles negative Y scales (common pattern: w 0 0 -h x y cm).
  M := E.Matrix;
  BX[0] := PageToBitmapX(Page, M.E);
  BY[0] := PageToBitmapY(Page, M.F);
  BX[1] := PageToBitmapX(Page, M.A + M.E);
  BY[1] := PageToBitmapY(Page, M.B + M.F);
  BX[2] := PageToBitmapX(Page, M.C + M.E);
  BY[2] := PageToBitmapY(Page, M.D + M.F);
  BX[3] := PageToBitmapX(Page, M.A + M.C + M.E);
  BY[3] := PageToBitmapY(Page, M.B + M.D + M.F);

  R.Left   := Min(Min(BX[0], BX[1]), Min(BX[2], BX[3]));
  R.Right  := Max(Max(BX[0], BX[1]), Max(BX[2], BX[3]));
  R.Top    := Min(Min(BY[0], BY[1]), Min(BY[2], BY[3]));
  R.Bottom := Max(Max(BY[0], BY[1]), Max(BY[2], BY[3]));

  if (R.Right <= R.Left) or (R.Bottom <= R.Top) then Exit;

  // JPEG magic bytes FF D8 — DCTDecode streams are returned undecoded.
  if (Length(E.Data) >= 2) and (E.Data[0] = $FF) and (E.Data[1] = $D8) then
  begin
    DrawJpegImage(Bitmap, R, E);
    Exit;
  end;

  // Image with a per-pixel /SMask -> composite with transparency (PNG alpha).
  if (Length(E.Alpha) = E.Width * E.Height) and (E.Width > 0) and (E.Height > 0) then
  begin
    DrawImageAlpha(Bitmap, R, E);
    Exit;
  end;

  // Resolve color space, including ICCBased fallback by pixel count.
  CS := E.ColorSpace;
  if SameText(CS, 'ICCBased') or (CS = '') then
  begin
    if (E.Width > 0) and (E.Height > 0) then
    begin
      if Length(E.Data) = E.Width * E.Height * 3 then CS := 'DeviceRGB'
      else if Length(E.Data) = E.Width * E.Height * 4 then CS := 'DeviceCMYK'
      else if Length(E.Data) = E.Width * E.Height then CS := 'DeviceGray';
    end;
  end;

  if SameText(CS, 'Indexed') then
    DrawIndexedImage(Bitmap, R, E)
  else if SameText(CS, 'DeviceRGB') or SameText(CS, 'CalRGB') then
    DrawRawDeviceRGB(Bitmap, R, E)
  else if SameText(CS, 'DeviceCMYK') then
    DrawRawDeviceCMYK(Bitmap, R, E)
  else if SameText(CS, 'DeviceGray') or SameText(CS, 'CalGray') then
    DrawRawDeviceGray(Bitmap, R, E)
  else
    DrawPlaceholder(Bitmap, R, E.Name);
end;

// Dispatch a single element to its type-specific draw routine (no mask).
procedure TPdfBitmapRenderer.DrawElementRaw(Bitmap: TBitmap; Page: TPdfPage; E: TPdfPageElement);
begin
  if E is TPdfShadingElement then
    DrawShadingElement(Bitmap, Page, TPdfShadingElement(E))
  else if E is TPdfPathElement then
    DrawPathElement(Bitmap, Page, TPdfPathElement(E))
  else if E is TPdfImageElement then
    DrawImageElement(Bitmap, Page, TPdfImageElement(E))
  else if E is TPdfTextElement then
    DrawTextElement(Bitmap, Page, TPdfTextElement(E));
end;

// Rasterize a soft mask's shape image into an 8-bit grayscale coverage buffer.
procedure TPdfBitmapRenderer.EnsureMaskGray(Mask: TPdfSoftMask);
var IE: TPdfImageElement;
  W, H, X, Y, stride, bpc, idx, bitpos, bytepos, shift, msk: Integer;
    RGB: TPdfBytes;
    rr,gg,bb: Integer;
begin
  if Mask.Built then Exit;
  Mask.Built := True;
  Mask.Valid := False;
  if not (Mask.MaskImage is TPdfImageElement) then Exit;
  IE := TPdfImageElement(Mask.MaskImage);
  W := IE.Width;
  H := IE.Height;
  if (W <= 0) or (H <= 0) or (Length(IE.Data) = 0) then Exit;

  if (Length(IE.Data) >= 2) and (IE.Data[0] = $FF) and (IE.Data[1] = $D8) then
  begin
    // Grayscale JPEG mask.
    if DecodeJpegToRGB(IE.Data, W, H, RGB) and (W > 0) and (H > 0) then
    begin
      SetLength(Mask.GrayData, W*H);
      for Y := 0 to H*W-1 do Mask.GrayData[Y] := RGB[Y*3];  // R channel (gray)
      Mask.W := W;
      Mask.H := H;
      Mask.Valid := True;
    end;
    Exit;
  end;

  bpc := IE.BitsPerComponent;
  if bpc <= 0 then bpc := 8;
  if SameText(IE.ColorSpace, 'DeviceGray') or SameText(IE.ColorSpace, 'CalGray') or (IE.ColorSpace = '') then
  begin
    stride := (W*bpc + 7) div 8;
    if Length(IE.Data) < stride*H then Exit;
    SetLength(Mask.GrayData, W*H);
    msk := (1 shl bpc) - 1;
    for Y := 0 to H-1 do
      for X := 0 to W-1 do
      begin
        if bpc = 8 then idx := IE.Data[Y*stride + X]
        else begin
          bitpos := X*bpc;
          bytepos := Y*stride + (bitpos div 8);
          shift := 8 - bpc - (bitpos mod 8);
          idx := ((IE.Data[bytepos] shr shift) and msk) * 255 div msk;
        end;
        Mask.GrayData[Y*W + X] := idx;
      end;
    Mask.W := W;
    Mask.H := H;
    Mask.Valid := True;
  end
  else if Length(IE.Data) = W*H*3 then  // RGB -> luminance
  begin
    SetLength(Mask.GrayData, W*H);
    for Y := 0 to W*H-1 do
    begin
      rr := IE.Data[Y*3];
      gg := IE.Data[Y*3+1];
      bb := IE.Data[Y*3+2];
      Mask.GrayData[Y] := (rr*77 + gg*150 + bb*29) shr 8;
    end;
    Mask.W := W;
    Mask.H := H;
    Mask.Valid := True;
  end;
end;

// Draw an element composited through its soft mask: render it to a temp copy,
// then alpha-blend onto the page using the mask's per-pixel coverage.
procedure TPdfBitmapRenderer.DrawMaskedElement(Bitmap: TBitmap; Page: TPdfPage; E: TPdfPageElement);
var Mask: TPdfSoftMask;
  Tmp, Src: TBitmap;
  px, py, L, T, Rr, Bt, W, H: Integer;
    cxs: array[0..3] of Double;
    cys: array[0..3] of Double;
    I, av: Integer;
    pageX, pageY, a: Double;
    TmpRow, SrcRow: PByte;
    mx0, my0, mx1, my1: Double;
    BF: TBlendFunction;
begin
  Mask := TPdfSoftMask(E.SoftMask);
  EnsureMaskGray(Mask);
  if not Mask.Valid then Exit;  // mask shape unavailable -> element hidden

  // Blend region = mask's page-space bounding box (∩ element clip, ∩ bitmap).
  cxs[0]:=Mask.Matrix.E;
  cys[0]:=Mask.Matrix.F;
  cxs[1]:=Mask.Matrix.A+Mask.Matrix.E;
  cys[1]:=Mask.Matrix.B+Mask.Matrix.F;
  cxs[2]:=Mask.Matrix.C+Mask.Matrix.E;
  cys[2]:=Mask.Matrix.D+Mask.Matrix.F;
  cxs[3]:=Mask.Matrix.A+Mask.Matrix.C+Mask.Matrix.E;
  cys[3]:=Mask.Matrix.B+Mask.Matrix.D+Mask.Matrix.F;
  mx0:=cxs[0];
  mx1:=cxs[0];
  my0:=cys[0];
  my1:=cys[0];
  for I:=1 to 3 do begin
    if cxs[I]<mx0 then mx0:=cxs[I];
    if cxs[I]>mx1 then mx1:=cxs[I];
    if cys[I]<my0 then my0:=cys[I];
    if cys[I]>my1 then my1:=cys[I];
  end;
  L := PageToBitmapX(Page, mx0);
  Rr := PageToBitmapX(Page, mx1);
  T := PageToBitmapY(Page, my1);
  Bt := PageToBitmapY(Page, my0);
  if E.HasClip then
  begin
    L := Max(L, Min(PageToBitmapX(Page,E.Clip.X1), PageToBitmapX(Page,E.Clip.X2)));
    Rr := Min(Rr, Max(PageToBitmapX(Page,E.Clip.X1), PageToBitmapX(Page,E.Clip.X2)));
    T := Max(T, Min(PageToBitmapY(Page,E.Clip.Y1), PageToBitmapY(Page,E.Clip.Y2)));
    Bt := Min(Bt, Max(PageToBitmapY(Page,E.Clip.Y1), PageToBitmapY(Page,E.Clip.Y2)));
  end;
  L := Max(L,0);
  T := Max(T,0);
  Rr := Min(Rr, Bitmap.Width-1);
  Bt := Min(Bt, Bitmap.Height-1);
  if (Rr < L) or (Bt < T) then Exit;
  W := Rr - L + 1;
  H := Bt - T + 1;

  // Render the element onto a copy of the page, then build a 32-bit premultiplied
  // BGRA source whose alpha is the mask coverage, and AlphaBlend it onto the page.
  // (We use GDI AlphaBlend rather than direct ScanLine writes because LCL Canvas
  // drawing methods on later elements discard ScanLine edits to the same bitmap.)
  Tmp := TBitmap.Create;
  Src := TBitmap.Create;
  try
    Tmp.PixelFormat := pf24bit;
    Tmp.SetSize(Bitmap.Width, Bitmap.Height);
    Tmp.Canvas.Draw(0, 0, Bitmap);
    DrawElementRaw(Tmp, Page, E);
    GdiFlush;

    Src.PixelFormat := pf32bit;
    Src.SetSize(W, H);
    for py := 0 to H-1 do
    begin
      TmpRow := Tmp.ScanLine[T + py];
      SrcRow := Src.ScanLine[py];
      pageY := Page.CropBox.Y2 - (T + py) / FOptions.Scale;
      for px := 0 to W-1 do
      begin
        pageX := (L + px) / FOptions.Scale + Page.CropBox.X1;
        a := Mask.AlphaAt(pageX, pageY);
        av := EnsureRange(Round(a*255), 0, 255);
        // Premultiplied BGRA for AC_SRC_ALPHA.
        SrcRow[px*4+0] := (TmpRow[(L+px)*3+0] * av) div 255;
        SrcRow[px*4+1] := (TmpRow[(L+px)*3+1] * av) div 255;
        SrcRow[px*4+2] := (TmpRow[(L+px)*3+2] * av) div 255;
        SrcRow[px*4+3] := av;
      end;
    end;

    BF.BlendOp := AC_SRC_OVER;
    BF.BlendFlags := 0;
    BF.SourceConstantAlpha := 255;
    BF.AlphaFormat := AC_SRC_ALPHA;
    AlphaBlend(Bitmap.Canvas.Handle, L, T, W, H, Src.Canvas.Handle, 0, 0, W, H, BF);
  finally
    Src.Free;
    Tmp.Free;
  end;
end;

// Build the effective clip region for an element: BaseRgn (the clip rectangle, or
// 0 for none) intersected with every non-rectangular clip path shape. Returns a
// new region the caller must select and DeleteObject (or 0 for no clip).
function TPdfBitmapRenderer.IntersectClipPaths(Page: TPdfPage; E: TPdfPageElement; BaseRgn: HRGN): HRGN;
var
  I, J, K, totPts, fillMode: Integer;
  CP: TPdfClipPath;
  Pts: array of TPoint;
  Counts: array of Integer;
  Rgn, Tmp: HRGN;
begin
  Result := BaseRgn;
  for I := 0 to High(E.ClipPaths) do
  begin
    CP := TPdfClipPath(E.ClipPaths[I]);
    if (CP = nil) or (Length(CP.SubPaths) = 0) then Continue;
    totPts := 0;
    for J := 0 to High(CP.SubPaths) do Inc(totPts, CP.SubPaths[J].Count);
    if totPts < 3 then Continue;
    SetLength(Pts, totPts);
    SetLength(Counts, Length(CP.SubPaths));
    K := 0;
    for J := 0 to High(CP.SubPaths) do
    begin
      Counts[J] := CP.SubPaths[J].Count;
      for totPts := 0 to CP.SubPaths[J].Count - 1 do
      begin
        Pts[K].X := PageToBitmapX(Page, CP.Points[CP.SubPaths[J].StartIdx + totPts].X);
        Pts[K].Y := PageToBitmapY(Page, CP.Points[CP.SubPaths[J].StartIdx + totPts].Y);
        Inc(K);
      end;
    end;
    if CP.EvenOdd then fillMode := ALTERNATE else fillMode := WINDING;
    Rgn := CreatePolyPolygonRgn(Pts[0], Counts[0], Length(Counts), fillMode);
    if Rgn = 0 then Continue;
    if Result = 0 then
      Result := Rgn
    else
    begin
      Tmp := CreateRectRgn(0, 0, 1, 1);
      CombineRgn(Tmp, Result, Rgn, RGN_AND);
      DeleteObject(Result);
      DeleteObject(Rgn);
      Result := Tmp;
    end;
  end;
end;

// Rotate a 24-bit bitmap clockwise by 90/180/270 degrees (per PDF /Rotate, which
// is the clockwise display rotation). Returns a new bitmap; dims swap for 90/270.
function RotateBitmap24(Src: TBitmap; Degrees: Integer): TBitmap;
var
  sw, sh, dw, dh, x, y, sx, sy: Integer;
  dp: PByte;
  srow: array of PByte;
begin
  Result := TBitmap.Create;
  Result.PixelFormat := pf24bit;
  sw := Src.Width; sh := Src.Height;
  if (Degrees = 90) or (Degrees = 270) then begin dw := sh; dh := sw; end
  else begin dw := sw; dh := sh; end;
  Result.SetSize(dw, dh);
  if (sw = 0) or (sh = 0) then Exit;
  SetLength(srow, sh);
  for y := 0 to sh - 1 do srow[y] := Src.ScanLine[y];
  sx := 0; sy := 0;
  for y := 0 to dh - 1 do
  begin
    dp := Result.ScanLine[y];
    for x := 0 to dw - 1 do
    begin
      case Degrees of
        90:  begin sx := y;          sy := sh - 1 - x; end;
        180: begin sx := sw - 1 - x; sy := sh - 1 - y; end;
        270: begin sx := sw - 1 - y; sy := x;          end;
      end;
      dp[x*3+0] := srow[sy][sx*3+0];
      dp[x*3+1] := srow[sy][sx*3+1];
      dp[x*3+2] := srow[sy][sx*3+2];
    end;
  end;
end;

procedure TPdfBitmapRenderer.RenderPageToBitmap(Page: TPdfPage; Bitmap: TBitmap);
var
  I: Integer;
  E: TPdfPageElement;
  W, H, Rot: Integer;
  ClipRgn: HRGN;
  cl, ct, cr, cb, t: Integer;
  Rotated: TBitmap;
begin
  if not Assigned(Page) then
    raise Exception.Create('Page is nil');
  if not Assigned(Bitmap) then
    raise Exception.Create('Bitmap is nil');
  Page.EnsureParsed;  // lazily interpret this page's content on first render

  // Render in unrotated page space; the whole bitmap is rotated at the end so
  // every element (text, images, paths) rotates together. pf24bit is required by
  // the ScanLine-based rotate.
  Rot := Page.Rotation;
  Bitmap.PixelFormat := pf24bit;
  W := Max(1, Round(Page.Width * FOptions.Scale));
  H := Max(1, Round(Page.Height * FOptions.Scale));
  Bitmap.SetSize(W, H);

  Bitmap.Canvas.Brush.Color := FOptions.BackgroundColor;
  Bitmap.Canvas.FillRect(0, 0, W, H);

  // Draw blue underlines for /Link annotations BEFORE text so text renders on top.
  // Use Min(Y1,Y2) — the lower PDF-space value is the bottom of the link rect,
  // just below the text baseline, regardless of whether the rect is stored
  // in standard or inverted (Y1>Y2) order.
  if Length(Page.LinkRects) > 0 then
  begin
    Bitmap.Canvas.Pen.Color := RGBToColor(0, 0, 220);
    Bitmap.Canvas.Pen.Width := Max(1, Round(FOptions.Scale));
    for I := 0 to High(Page.LinkRects) do
    begin
      Bitmap.Canvas.MoveTo(
        PageToBitmapX(Page, Page.LinkRects[I].X1),
        PageToBitmapY(Page, Min(Page.LinkRects[I].Y1, Page.LinkRects[I].Y2)));
      Bitmap.Canvas.LineTo(
        PageToBitmapX(Page, Page.LinkRects[I].X2),
        PageToBitmapY(Page, Min(Page.LinkRects[I].Y1, Page.LinkRects[I].Y2)));
    end;
  end;

  Bitmap.Canvas.Pen.Color := FOptions.StrokeColor;

  for I := 0 to Page.Elements.Count - 1 do
  begin
    E := TPdfPageElement(Page.Elements[I]);

    // Apply the element's clip (from a PDF W/W* clip) for this draw: the bounding
    // rectangle intersected with any non-rectangular clip path shapes. EXCEPTION:
    // a shading clipped to a shape applies that clip itself as an antialiased
    // coverage mask (DrawShadingElement), so don't impose the binary GDI region
    // here — it would hard-clip the soft edges back to jagged.
    ClipRgn := 0;
    if not ((E is TPdfShadingElement) and (Length(E.ClipPaths) > 0) and GGdiplusOK and FOptions.AntialiasVectors) then
    begin
      if E.HasClip then
      begin
        cl := PageToBitmapX(Page, E.Clip.X1);
        cr := PageToBitmapX(Page, E.Clip.X2);
        ct := PageToBitmapY(Page, E.Clip.Y2);  // larger page-Y maps to smaller bitmap-Y
        cb := PageToBitmapY(Page, E.Clip.Y1);
        if cr < cl then begin
          t := cl;
          cl := cr;
          cr := t;
        end;
        if cb < ct then begin
          t := ct;
          ct := cb;
          cb := t;
        end;
        ClipRgn := CreateRectRgn(cl, ct, cr + 1, cb + 1);
      end;
      ClipRgn := IntersectClipPaths(Page, E, ClipRgn);
    end;
    if ClipRgn <> 0 then SelectClipRgn(Bitmap.Canvas.Handle, ClipRgn);

    if Assigned(E.SoftMask) then
      DrawMaskedElement(Bitmap, Page, E)
    else
      DrawElementRaw(Bitmap, Page, E);

    if ClipRgn <> 0 then
    begin
      SelectClipRgn(Bitmap.Canvas.Handle, 0);
      DeleteObject(ClipRgn);
    end;
  end;

  // Apply the page's /Rotate by rotating the finished bitmap.
  if (Rot = 90) or (Rot = 180) or (Rot = 270) then
  begin
    Rotated := RotateBitmap24(Bitmap, Rot);
    try
      Bitmap.SetSize(Rotated.Width, Rotated.Height);
      Bitmap.Canvas.Draw(0, 0, Rotated);
    finally
      Rotated.Free;
    end;
  end;
end;

function TPdfBitmapRenderer.RenderPageToBitmap(Page: TPdfPage): TBitmap;
begin
  Result := TBitmap.Create;
  try
    RenderPageToBitmap(Page, Result);
  except
    Result.Free;
    raise;
  end;
end;

procedure TPdfBitmapRenderer.RenderDocumentToBitmaps(Doc: TPdfDocument; List: TList);
var
  I: Integer;
  B: TBitmap;
begin
  if not Assigned(Doc) then
    raise Exception.Create('Document is nil');
  if not Assigned(List) then
    raise Exception.Create('List is nil');

  for I := 0 to Doc.Pages.Count - 1 do
  begin
    B := RenderPageToBitmap(TPdfPage(Doc.Pages[I]));
    List.Add(B);
  end;
end;

procedure InitGdiplus;
var si: TGdiplusStartupInput;
begin
  si.GdiplusVersion := 1;
  si.DebugEventCallback := nil;
  si.SuppressBackgroundThread := False;
  si.SuppressExternalCodecs := False;
  GGdiplusOK := GdiplusStartup(GGdiplusToken, si, nil) = 0;
end;

initialization
  InitGdiplus;
finalization
  if GGdiplusOK then GdiplusShutdown(GGdiplusToken);
end.
