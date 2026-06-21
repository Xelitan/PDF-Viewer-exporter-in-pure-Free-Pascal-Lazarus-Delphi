unit XelPDF;
{$mode delphi}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
//Visual PDF viewer component
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
//Features: scrollable multi-page display, text search with highlight,
//text selection, copy to clipboard.

interface

uses
  Classes, SysUtils, Math, Contnrs,
  LCLType, LCLIntf,
  Controls, StdCtrls, Graphics, Clipbrd, Forms, Dialogs, Printers,
  PdfParser, PdfBitmapRenderer, PdfMarkdown, PdfTypes;

const
  XELPDF_PAGE_SPACING   = 12;
  XELPDF_SCROLLBAR_W    = 17;
  XELPDF_DEFAULT_SCALE  = 2.0;

type
  // Blend function record — declared here to avoid importing the Windows unit
  // (which would conflict with Graphics.TBitmap used by PdfBitmapRenderer).
  TXelBlendFunction = packed record
    BlendOp             : Byte;
    BlendFlags          : Byte;
    SourceConstantAlpha : Byte;
    AlphaFormat         : Byte;
  end;

  TXelSearchResult = record
    PageIndex    : Integer;
    ElementIndex : Integer;
    Bounds       : TPdfRect;
  end;

  // Page-fit mode (see TXelPDF.AutoFit):
  // afNone   - fixed Scale, no fitting (default; current behaviour)
  // afWidth  - scale so the page width fills the component width
  // afHeight - scale so the page height fills the component height
  TXelAutoFit = (afNone, afWidth, afHeight);

  TXelPDF = class(TCustomControl)
  private
    FDocument     : TPdfDocument;
    FRenderer     : TPdfBitmapRenderer;
    FScrollBar    : TScrollBar;
    FPageBitmaps  : array of TBitmap;
    FPageOffsets  : array of Integer;  // pixel Y of top of each page in full-doc space
    FTotalHeight  : Integer;
    FScrollPos    : Integer;
    FScale        : Double;
    FPageSpacing  : Integer;
    FPageCount    : Integer;  // total pages (PDF or text)
    FIsTextFile   : Boolean;  // True when a .txt file is loaded
    FAutoFit      : TXelAutoFit;  // page-fit mode

    // Search
    FSearchResults     : array of TXelSearchResult;
    FSearchResultCount : Integer;
    FCurrentResult     : Integer;
    FSearchText        : string;

    // Text selection
    FSelecting   : Boolean;
    FHasSelection: Boolean;
    FSelX1, FSelY1 : Integer;  // screen coords, anchor
    FSelX2, FSelY2 : Integer;  // screen coords, drag end

    function  ContentWidth: Integer;
    procedure LayoutPages;
    procedure EnsurePageBitmap(PageIndex: Integer);
    procedure DoSetScrollPos(APos: Integer);
    procedure UpdateScrollBarRange;
    procedure ScrollBarChange(Sender: TObject);
    function  GetCurrentPage: Integer;
    function  GetSearchResultCount: Integer;
    procedure SetScale(AScale: Double);
    procedure SetAutoFit(AValue: TXelAutoFit);
    procedure ApplyAutoFit;  // recompute FScale from FAutoFit + component size
    procedure LoadText(const FileName: string);
    procedure LoadMarkdown(const FileName: string);
    procedure LoadPdfWithPasswordPrompt(const FileName: string);

    // Coordinate helpers
    function PageScreenRect(PageIndex: Integer): TRect;
    function PdfToScreen(PageIndex: Integer; const R: TPdfRect): TRect;
    // Hyperlinks: find the external URL whose link rect contains widget point (X,Y).
    function LinkAtPoint(X, Y: Integer; out URL: string): Boolean;

    // Drawing helpers
    procedure DrawAlphaRect(const R: TRect; Color: TColor; Alpha: Byte);
    procedure DrawSearchHighlights(PageIndex: Integer);
    procedure DrawSelectionOverlay(PageIndex: Integer);

    // Clipboard helper
    function GetSelectedText: string;

  protected
    procedure Paint;
    override;
    procedure Resize;
    override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer);
    override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
    override;
    procedure KeyDown(var Key: Word; Shift: TShiftState);
    override;
    function  DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
                           MousePos: TPoint): Boolean;
                           override;

  public
    constructor Create(AOwner: TComponent);
    override;
    destructor  Destroy;
    override;

    procedure LoadFromFile(const FileName: string);

    // Search for AText across all pages.
    // Returns number of matches found.
    // Scrolls to the first match automatically.
    function  Search(const AText: string): Integer;
    procedure SearchNext;
    procedure SearchPrev;
    procedure ClearSearch;

    // Copy currently selected text to clipboard.
    procedure CopySelectionToClipboard;

    // Scroll so that PageIndex is at the top of the viewport.
    procedure ScrollToPage(PageIndex: Integer);

    // Drop cached page bitmaps and re-lay-out, then repaint. Call this after
    // changing the document behind the viewer's back (e.g. Document.RotateRight/
    // RotateLeft, AddText, DrawRect, RemovePage). Plain Refresh/Repaint don't
    // help because rendered pages are cached and only rebuilt when nil.
    procedure RefreshView;

    // Print a range of pages on the default printer. Each page is rendered to a
    // memory bitmap at the printer's resolution (capped to bound memory) and then
    // blitted onto the paper, scaled to fit the printable area, aspect kept.
    // FromPage/ToPage are 0-based, inclusive; the defaults (0 .. MaxInt) print
    // every page. The range is clamped to the document's page count.
    procedure Print(const JobTitle: string = 'PDF Document';
                    FromPage: Integer = 0; ToPage: Integer = MaxInt);

    property SearchResultCount : Integer read GetSearchResultCount;
    property Scale             : Double  read FScale write SetScale;
    property Document          : TPdfDocument read FDocument;
    // Page-fit mode. afWidth/afHeight keep the page sized to the component's
    // width/height (recomputed on resize); afNone uses the fixed Scale.
    property AutoFit           : TXelAutoFit read FAutoFit write SetAutoFit;

  published
    property CurrentPage       : Integer read GetCurrentPage;
    property Align;
    property Anchors;
    property Color default clDkGray;
    property Enabled;
    property Font;
    property TabOrder;
    property TabStop default True;
    property Visible;
    property OnClick;
    property OnDblClick;
    property OnKeyDown;
    property OnKeyPress;
    property OnKeyUp;
    property OnMouseDown;
    property OnMouseMove;
    property OnMouseUp;
    property OnResize;
  end;

procedure Register;

implementation

// Declare AlphaBlend from msimg32.dll without pulling in the Windows unit.
function WinAlphaBlend(DC: HDC; X, Y, W, H: Integer; SrcDC: HDC;
  SX, SY, SW, SH: Integer; BF: TXelBlendFunction): LongBool;
  stdcall;
  external 'msimg32.dll' name 'AlphaBlend';

function RectsOverlap(const A, B: TRect): Boolean;
inline;
begin
  Result := (A.Left < B.Right) and (A.Right > B.Left) and
            (A.Top  < B.Bottom) and (A.Bottom > B.Top);
end;

// Flow-style selection test.
// (AX1,AY1) = mouse-down anchor; (AX2,AY2) = current/release position.
// Normalise by Y so TopY <= BotY, but remember which endpoint is the
// anchor so the X rules stay correct for both downward AND upward drags.
//
// Anchor row  → select from anchorX  to end-of-line  (SR.Right > anchorX)
// Cursor row  → select from start-of-line to cursorX  (SR.Left  < cursorX)
// Single-line → X must overlap [min(anchorX,cursorX), max(anchorX,cursorX)]
// Middle rows → no X constraint
function IsTextInSelection(const SR: TRect; AX1, AY1, AX2, AY2: Integer): Boolean;
var
  TopX, TopY, BotX, BotY : Integer;
  AnchorX, CursorX       : Integer;
  AnchorIsTop            : Boolean;
  StartsHere, EndsHere   : Boolean;
begin
  // Normalise Y — remember which side the anchor is on
  if AY1 <= AY2 then begin
    TopX := AX1;
    TopY := AY1;
    BotX := AX2;
    BotY := AY2;
    AnchorIsTop := True;  // anchor (AX1,AY1) is the top endpoint
  end else begin
    TopX := AX2;
    TopY := AY2;
    BotX := AX1;
    BotY := AY1;
    AnchorIsTop := False;  // anchor (AX1,AY1) is the bottom endpoint
  end;

  // Derive which X belongs to anchor vs cursor
  if AnchorIsTop then begin
    AnchorX := TopX;
    CursorX := BotX;
  end else begin
    AnchorX := BotX;
    CursorX := TopX;
  end;

  // No vertical overlap at all
  if (SR.Bottom <= TopY) or (SR.Top >= BotY) then begin
    Result := False;
    Exit;
  end;

  StartsHere := (TopY >= SR.Top) and (TopY < SR.Bottom);
  EndsHere   := (BotY >  SR.Top) and (BotY <= SR.Bottom);

  if StartsHere and EndsHere then
    // Single-line drag: X must fall inside [min, max] of both endpoints
    Result := (SR.Right > Min(AnchorX, CursorX)) and (SR.Left < Max(AnchorX, CursorX))
  else if StartsHere then begin
    // Top row
    if AnchorIsTop then
      Result := SR.Right > AnchorX   // anchor row: from anchorX to end of line
    else
      Result := SR.Left  < CursorX;  // cursor row: from start of line to cursorX
  end else if EndsHere then begin
    // Bottom row
    if AnchorIsTop then
      Result := SR.Left  < CursorX   // cursor row: from start of line to cursorX
    else
      Result := SR.Right > AnchorX;  // anchor row: from anchorX to end of line
  end else
    // Middle row — fully covered, no X constraint
    Result := True;
end;

// Approximate the PDF-space bounding rect for a text element.
// The parser never populates TPdfPageElement.Bounds, so we derive it from the
// text rendering matrix (E,F = baseline origin in page coords, A/D = CTM scale)
// and the stored font size. Selection and search highlighting need only element-
// level granularity, so a rough average-glyph-width estimate is fine.
function TextElemApproxPdfRect(E: TPdfTextElement): TPdfRect;
var
  ScaleX, ScaleY, H, W: Double;
begin
  // Prefer the exact bounds written by the parser (using real font advance widths).
  if (E.Bounds.X2 > E.Bounds.X1) or (E.Bounds.Y2 > E.Bounds.Y1) then
  begin
    Result := E.Bounds;
    Exit;
  end;

  // Fallback for elements where the parser left Bounds at zero
  // (e.g. empty strings or fonts without width tables).
  ScaleY := Abs(E.Matrix.D);
  ScaleX := Abs(E.Matrix.A);
  if ScaleY < 0.01 then ScaleY := 1.0;
  if ScaleX < 0.01 then ScaleX := ScaleY;

  H := E.FontSize * ScaleY;
  W := E.FontSize * ScaleX * Length(E.Text) * 0.55;
  if W < H then W := H;

  Result.X1 := E.Matrix.E;
  Result.X2 := E.Matrix.E + W;
  Result.Y1 := E.Matrix.F - H * 0.2;
  Result.Y2 := E.Matrix.F + H;
end;

// Return the PDF-space bounding rect of character CI (0-based) within E.
// Uses the per-character advance widths stored by the parser.
function CharPdfRect(E: TPdfTextElement; CI: Integer): TPdfRect;
var
  I: Integer;
  CumW: Double;
begin
  CumW := 0;
  for I := 0 to CI - 1 do
    if I < Length(E.CharWidths) then
      CumW := CumW + E.CharWidths[I];
  Result.X1 := E.Bounds.X1 + CumW;
  if CI < Length(E.CharWidths) then
    Result.X2 := Result.X1 + E.CharWidths[CI]
  else
    Result.X2 := E.Bounds.X2;
  Result.Y1 := E.Bounds.Y1;
  Result.Y2 := E.Bounds.Y2;
end;

// TXelPDF

constructor TXelPDF.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FScale        := XELPDF_DEFAULT_SCALE;
  FPageSpacing  := XELPDF_PAGE_SPACING;
  FAutoFit      := afNone;
  FDocument     := TPdfDocument.Create;
  FRenderer     := TPdfBitmapRenderer.Create;
  FRenderer.Options := TPdfBitmapRenderer.DefaultOptions;
  FCurrentResult     := -1;
  FSearchResultCount := 0;
  FHasSelection := False;
  FSelecting    := False;
  Color    := clDkGray;
  TabStop  := True;
  Width    := 600;
  Height   := 800;
  ControlStyle := ControlStyle + [csCaptureMouse];

  FScrollBar := TScrollBar.Create(Self);
  FScrollBar.Kind        := TScrollBarKind(1);  // 1 = sbVertical
  FScrollBar.Parent      := Self;
  FScrollBar.SmallChange := 40;
  FScrollBar.Min         := 0;
  FScrollBar.Max         := 0;
  FScrollBar.Position    := 0;
  FScrollBar.SetBounds(Width - XELPDF_SCROLLBAR_W, 0, XELPDF_SCROLLBAR_W, Height);
  FScrollBar.OnChange    := ScrollBarChange;
end;

destructor TXelPDF.Destroy;
var I: Integer;
begin
  for I := 0 to High(FPageBitmaps) do
    FPageBitmaps[I].Free;
  FDocument.Free;
  FRenderer.Free;
  inherited Destroy;
end;

function TXelPDF.ContentWidth: Integer;
begin
  Result := Width - XELPDF_SCROLLBAR_W;
end;

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

procedure TXelPDF.LoadFromFile(const FileName: string);
var I: Integer;
begin
  // Clear previous content
  for I := 0 to High(FPageBitmaps) do
    FPageBitmaps[I].Free;
  SetLength(FPageBitmaps, 0);
  SetLength(FPageOffsets, 0);
  FPageCount := 0;
  ClearSearch;
  FHasSelection := False;
  FSelecting    := False;
  FScrollPos    := 0;

  if LowerCase(ExtractFileExt(FileName)) = '.txt' then
    LoadText(FileName)          // generates a PDF internally, then loads it
  else if (LowerCase(ExtractFileExt(FileName)) = '.md') or
          (LowerCase(ExtractFileExt(FileName)) = '.markdown') then
    LoadMarkdown(FileName)      // converts Markdown -> PDF, then loads it
  else begin
    FIsTextFile := False;
    LoadPdfWithPasswordPrompt(FileName);
    LayoutPages;
    if FAutoFit <> afNone then ApplyAutoFit;  // fit to component on open
  end;
  Invalidate;
end;

// Load a PDF, prompting (and retrying) for a password if it is encrypted and the
// empty password does not unlock it. Cancelling the prompt re-raises so the
// caller can decide what to do (the main form shows an error / leaves it closed).
procedure TXelPDF.LoadPdfWithPasswordPrompt(const FileName: string);
var pw: string;
begin
  try
    FDocument.LoadFromFile(FileName);  // empty password first
  except
    on EPdfPasswordRequired do
    begin
      pw := '';
      while True do
      begin
        if not InputQuery('Password required',
             'This PDF is password protected.' + LineEnding + 'Enter password:', True, pw) then
          Abort;  // user cancelled
        try
          FDocument.LoadFromFile(FileName, pw);
          Break;  // unlocked
        except
          on EPdfPasswordRequired do
            MessageDlg('Incorrect password', 'The password is incorrect. Please try again.',
                       mtWarning, [mbOK], 0);
        end;
      end;
    end;
  end;
end;

procedure TXelPDF.LayoutPages;
var
  I, Y, PageH, PageCount: Integer;
  Page: TPdfPage;
begin
  PageCount  := FDocument.Pages.Count;
  FPageCount := PageCount;
  SetLength(FPageBitmaps, PageCount);
  SetLength(FPageOffsets, PageCount);
  for I := 0 to PageCount - 1 do
    FPageBitmaps[I] := nil;

  Y := FPageSpacing;
  for I := 0 to PageCount - 1 do
  begin
    FPageOffsets[I] := Y;
    Page := TPdfPage(FDocument.Pages[I]);
    PageH := Round(Page.EffectiveHeight * FScale);   // /Rotate-aware (swaps for 90/270)
    Inc(Y, PageH + FPageSpacing);
  end;
  FTotalHeight := Y;
  UpdateScrollBarRange;
end;

procedure TXelPDF.EnsurePageBitmap(PageIndex: Integer);
var
  Opts: TPdfBitmapRenderOptions;
begin
  if FPageBitmaps[PageIndex] <> nil then Exit;  // already rendered (or pre-built by LoadText)
  if FIsTextFile then Exit;  // text pages are pre-built in LoadText
  Opts := FRenderer.Options;
  Opts.Scale := FScale;
  FRenderer.Options := Opts;
  FPageBitmaps[PageIndex] :=
    FRenderer.RenderPageToBitmap(TPdfPage(FDocument.Pages[PageIndex]));
end;

// ---------------------------------------------------------------------------
// Scale
// ---------------------------------------------------------------------------

procedure TXelPDF.SetScale(AScale: Double);
var
  I, OldPage: Integer;
begin
  if Abs(FScale - AScale) < 0.001 then Exit;
  OldPage := GetCurrentPage;
  FScale  := AScale;
  for I := 0 to High(FPageBitmaps) do
  begin
    FPageBitmaps[I].Free;
    FPageBitmaps[I] := nil;
  end;
  if (not FIsTextFile) and (FDocument.Pages.Count > 0) then
  begin
    LayoutPages;
    ScrollToPage(OldPage);
  end;
  Invalidate;
end;

procedure TXelPDF.SetAutoFit(AValue: TXelAutoFit);
begin
  if FAutoFit = AValue then Exit;
  FAutoFit := AValue;
  ApplyAutoFit;
end;

// Force a full re-render: free every cached page bitmap so Paint rebuilds them
// from the current document state, recompute the layout (a rotation swaps a
// page's effective width/height) and repaint. Without this an external change
// like Document.RotateRight is invisible, because EnsurePageBitmap keeps the
// stale cached bitmap and only renders when the slot is nil.
procedure TXelPDF.RefreshView;
var
  I, OldPage: Integer;
begin
  OldPage := GetCurrentPage;
  for I := 0 to High(FPageBitmaps) do
  begin
    FPageBitmaps[I].Free;
    FPageBitmaps[I] := nil;
  end;
  if (not FIsTextFile) and Assigned(FDocument) and (FDocument.Pages.Count > 0) then
  begin
    if FAutoFit <> afNone then ApplyAutoFit;  // re-fit: rotation changes page W/H
    LayoutPages;
    ScrollToPage(OldPage);
  end;
  Invalidate;
end;

// ---------------------------------------------------------------------------
// Printing
// ---------------------------------------------------------------------------
//
// We do NOT drive GDI/GDI+ primitives straight onto the printer DC. The page
// renderer composites transparency and ExtGState soft masks by reading pixels
// back (ScanLine / AlphaBlend), which printer DCs don't support. Instead each
// page is rendered into a memory bitmap at the printer's resolution -- there the
// renderer's full GDI+ pipeline (vector antialiasing, image scaling) runs
// normally -- and the finished bitmap is blitted onto the paper. Rendering at
// print DPI means the final blit is ~1:1, so no quality is lost scaling on the
// printer side.
procedure TXelPDF.Print(const JobTitle: string; FromPage: Integer; ToPage: Integer);
var
  I: Integer;
  Page: TPdfPage;
  Bmp: TBitmap;
  SavedOpts, Opts: TPdfBitmapRenderOptions;
  pageWpt, pageHpt, dotsW, dotsH, fit, renderScale, maxScale: Double;
  destW, destH, offX, offY: Integer;
begin
  if (not Assigned(FDocument)) or (FDocument.Pages.Count = 0) then Exit;
  // Clamp the requested range to valid page indices.
  if FromPage < 0 then FromPage := 0;
  if ToPage > FDocument.Pages.Count - 1 then ToPage := FDocument.Pages.Count - 1;
  if FromPage > ToPage then Exit;  // empty range
  SavedOpts := FRenderer.Options;
  Printer.Title := JobTitle;
  Printer.BeginDoc;
  try
    // Cap render resolution to ~300 DPI: an A4 page at 600 DPI would be a
    // ~100 MB bitmap. 300 DPI is plenty for text and line art.
    maxScale := 300.0 / 72.0;
    for I := FromPage to ToPage do
    begin
      if I > FromPage then Printer.NewPage;
      Page := TPdfPage(FDocument.Pages[I]);
      pageWpt := Page.EffectiveWidth;
      pageHpt := Page.EffectiveHeight;
      if (pageWpt <= 0) or (pageHpt <= 0) then Continue;
      // Page size in printer dots at 100% (1 pt = 1/72").
      dotsW := pageWpt / 72.0 * Printer.XDPI;
      dotsH := pageHpt / 72.0 * Printer.YDPI;
      // Fit to the printable area, keep aspect ratio, never upscale past 100%.
      fit := Min(Printer.PageWidth / dotsW, Printer.PageHeight / dotsH);
      if fit > 1.0 then fit := 1.0;
      destW := Max(1, Round(dotsW * fit));
      destH := Max(1, Round(dotsH * fit));
      // Render the bitmap at the on-paper device size, capped at maxScale.
      renderScale := destW / pageWpt;       // pixels per PDF point
      if renderScale > maxScale then renderScale := maxScale;
      Opts := SavedOpts;
      Opts.Scale := renderScale;
      FRenderer.Options := Opts;
      Bmp := FRenderer.RenderPageToBitmap(Page);
      try
        offX := (Printer.PageWidth  - destW) div 2;   // centre on the sheet
        offY := (Printer.PageHeight - destH) div 2;
        Printer.Canvas.StretchDraw(Rect(offX, offY, offX + destW, offY + destH), Bmp);
      finally
        Bmp.Free;
      end;
    end;
    Printer.EndDoc;
  except
    Printer.Abort;
    FRenderer.Options := SavedOpts;
    raise;
  end;
  FRenderer.Options := SavedOpts;
end;

// Recompute the render scale so the first page's width (afWidth) or height
// (afHeight) matches the component. No-op for text files / afNone / no document.
procedure TXelPDF.ApplyAutoFit;
var pageW, pageH, target: Double;
begin
  if FIsTextFile or (FAutoFit = afNone) then Exit;
  if (not Assigned(FDocument)) or (FDocument.Pages.Count = 0) then Exit;
  pageW := TPdfPage(FDocument.Pages[0]).EffectiveWidth;
  pageH := TPdfPage(FDocument.Pages[0]).EffectiveHeight;
  target := FScale;
  case FAutoFit of
    afWidth:  if pageW > 0 then target := ContentWidth / pageW;  // fit visible width
    afHeight: if pageH > 0 then target := Height / pageH;  // fit component height
  end;
  if target < 0.05 then target := 0.05;
  SetScale(target);
end;

// ---------------------------------------------------------------------------
// Scrollbar
// ---------------------------------------------------------------------------

procedure TXelPDF.UpdateScrollBarRange;
begin
  FScrollBar.SetBounds(Width - XELPDF_SCROLLBAR_W, 0, XELPDF_SCROLLBAR_W, Height);
  FScrollBar.LargeChange := Max(1, Height - FPageSpacing);
  if FTotalHeight <= Height then
  begin
    FScrollBar.Max      := 0;
    FScrollBar.Position := 0;
    FScrollPos          := 0;
  end
  else
  begin
    FScrollBar.Max := FTotalHeight - Height;
    if FScrollPos > FScrollBar.Max then
      FScrollPos := FScrollBar.Max;
    FScrollBar.Position := FScrollPos;
  end;
end;

procedure TXelPDF.ScrollBarChange(Sender: TObject);
begin
  if FScrollBar.Position = FScrollPos then Exit;
  FScrollPos := FScrollBar.Position;
  Invalidate;
end;

procedure TXelPDF.DoSetScrollPos(APos: Integer);
var MaxPos: Integer;
begin
  MaxPos := Max(0, FTotalHeight - Height);
  APos   := Max(0, Min(APos, MaxPos));
  if APos = FScrollPos then Exit;
  FScrollPos := APos;
  if FScrollBar.Position <> APos then
    FScrollBar.Position := APos;
  Invalidate;
end;

// ---------------------------------------------------------------------------
// Public navigation
// ---------------------------------------------------------------------------

procedure TXelPDF.ScrollToPage(PageIndex: Integer);
begin
  if (PageIndex < 0) or (PageIndex >= Length(FPageOffsets)) then Exit;
  DoSetScrollPos(Max(0, FPageOffsets[PageIndex] - FPageSpacing));
end;

function TXelPDF.GetCurrentPage: Integer;
var
  I, CenterY: Integer;
begin
  Result := 0;
  if Length(FPageOffsets) = 0 then Exit;
  CenterY := FScrollPos + Height div 2;
  for I := 0 to High(FPageOffsets) do
    if FPageOffsets[I] <= CenterY then
      Result := I;
end;

function TXelPDF.GetSearchResultCount: Integer;
begin
  Result := FSearchResultCount;
end;

// ---------------------------------------------------------------------------
// Coordinate helpers
// ---------------------------------------------------------------------------

function TXelPDF.PageScreenRect(PageIndex: Integer): TRect;
var
  Page: TPdfPage;
  PageW, PageH, CX, PX: Integer;
begin
  if FIsTextFile then
  begin
    // Text pages — dimensions come from the pre-built bitmap.
    if (PageIndex < Length(FPageBitmaps)) and (FPageBitmaps[PageIndex] <> nil) then
    begin
      PageW := FPageBitmaps[PageIndex].Width;
      PageH := FPageBitmaps[PageIndex].Height;
    end else begin
      PageW := ContentWidth;
      PageH := 200;
    end;
  end else begin
    Page  := TPdfPage(FDocument.Pages[PageIndex]);
    PageW := Round(Page.EffectiveWidth  * FScale);   // /Rotate-aware
    PageH := Round(Page.EffectiveHeight * FScale);
  end;
  CX    := ContentWidth;
  PX    := (CX - PageW) div 2;
  if PX < 0 then PX := 0;
  Result.Left   := PX;
  Result.Top    := FPageOffsets[PageIndex] - FScrollPos;
  Result.Right  := PX + PageW;
  Result.Bottom := Result.Top + PageH;
end;

function TXelPDF.PdfToScreen(PageIndex: Integer; const R: TPdfRect): TRect;
var
  PR   : TRect;
  Page : TPdfPage;
begin
  PR   := PageScreenRect(PageIndex);
  Page := TPdfPage(FDocument.Pages[PageIndex]);
  // Mirror PdfBitmapRenderer.PageToBitmapX/Y exactly:
  //   BitmapX = (pdfX - CropBox.X1) * Scale
  //   BitmapY = (CropBox.Y2 - pdfY)  * Scale
  Result.Left   := PR.Left + Round((R.X1 - Page.CropBox.X1) * FScale);
  Result.Right  := PR.Left + Round((R.X2 - Page.CropBox.X1) * FScale);
  Result.Top    := PR.Top  + Round((Page.CropBox.Y2 - R.Y2)  * FScale);
  Result.Bottom := PR.Top  + Round((Page.CropBox.Y2 - R.Y1)  * FScale);
end;

// ---------------------------------------------------------------------------
// Alpha-blend drawing helper
// ---------------------------------------------------------------------------

procedure TXelPDF.DrawAlphaRect(const R: TRect; Color: TColor; Alpha: Byte);
var
  Tmp : TBitmap;
  BF  : TXelBlendFunction;
  W, H: Integer;
begin
  W := R.Right - R.Left;
  H := R.Bottom - R.Top;
  if (W <= 0) or (H <= 0) then Exit;

  Tmp := TBitmap.Create;
  try
    Tmp.SetSize(W, H);
    Tmp.Canvas.Brush.Color := Color;
    Tmp.Canvas.FillRect(Rect(0, 0, W, H));

    BF.BlendOp             := 0;  // AC_SRC_OVER
    BF.BlendFlags          := 0;
    BF.SourceConstantAlpha := Alpha;
    BF.AlphaFormat         := 0;

    WinAlphaBlend(
      Canvas.Handle,
      R.Left, R.Top, W, H,
      Tmp.Canvas.Handle,
      0, 0, W, H,
      BF);
  finally
    Tmp.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Paint
// ---------------------------------------------------------------------------

procedure TXelPDF.DrawSearchHighlights(PageIndex: Integer);
var
  I  : Integer;
  SR : TRect;
begin
  if FSearchResultCount = 0 then Exit;
  for I := 0 to FSearchResultCount - 1 do
  begin
    if FSearchResults[I].PageIndex <> PageIndex then Continue;
    SR := PdfToScreen(PageIndex, FSearchResults[I].Bounds);
    if I = FCurrentResult then
      DrawAlphaRect(SR, $0040A0FF, 180)   // active result: orange, more opaque
    else
      DrawAlphaRect(SR, $0000FFFF, 110);  // other results: yellow, lighter
  end;
end;

procedure TXelPDF.DrawSelectionOverlay(PageIndex: Integer);
var
  EI, CI     : Integer;
  Page       : TPdfPage;
  Elem       : TPdfPageElement;
  TextElem   : TPdfTextElement;
  CharR, Run : TRect;
  RunActive  : Boolean;
begin
  if not (FSelecting or FHasSelection) then Exit;
  if (Abs(FSelX2 - FSelX1) <= 2) and (Abs(FSelY2 - FSelY1) <= 2) then Exit;
  if FIsTextFile then Exit;  // text pages: no element-level selection

  Page      := TPdfPage(FDocument.Pages[PageIndex]);
  Page.EnsureParsed;
  RunActive := False;
  Run       := Rect(0, 0, 0, 0);

  for EI := 0 to Page.Elements.Count - 1 do
  begin
    Elem := TPdfPageElement(Page.Elements[EI]);
    if Elem.Kind <> pekText then Continue;
    TextElem := TPdfTextElement(Elem);

    for CI := 0 to Length(TextElem.Text) - 1 do
    begin
      if CI >= Length(TextElem.CharWidths) then Continue;
      CharR := PdfToScreen(PageIndex, CharPdfRect(TextElem, CI));
      if IsTextInSelection(CharR, FSelX1, FSelY1, FSelX2, FSelY2) then
      begin
        // Merge into current run if on the same line and touching
        if RunActive
           and (Abs(CharR.Top    - Run.Top)    <= 2)
           and (Abs(CharR.Bottom - Run.Bottom) <= 2)
           and (CharR.Left <= Run.Right + 2) then
          Run.Right := CharR.Right
        else
        begin
          if RunActive then DrawAlphaRect(Run, clHighlight, 130);
          Run       := CharR;
          RunActive := True;
        end;
      end
      else
      begin
        if RunActive then begin
          DrawAlphaRect(Run, clHighlight, 130);
          RunActive := False;
        end;
      end;
    end;
  end;
  if RunActive then DrawAlphaRect(Run, clHighlight, 130);
end;

procedure TXelPDF.Paint;
var
  I  : Integer;
  PR : TRect;
begin
  // Background for page area and scrollbar gutter
  Canvas.Brush.Color := Color;
  Canvas.FillRect(Rect(0, 0, ContentWidth, Height));
  Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(Rect(ContentWidth, 0, Width, Height));

  if FPageCount = 0 then Exit;

  for I := 0 to FPageCount - 1 do
  begin
    PR := PageScreenRect(I);
    if PR.Bottom < 0   then Continue;
    if PR.Top    > Height then Break;

    EnsurePageBitmap(I);
    if FPageBitmaps[I] <> nil then
      Canvas.Draw(PR.Left, PR.Top, FPageBitmaps[I]);

    DrawSearchHighlights(I);
    DrawSelectionOverlay(I);
  end;
end;

function TXelPDF.LinkAtPoint(X, Y: Integer; out URL: string): Boolean;
var I, J, t: Integer;
  PR, LR: TRect;
  Page: TPdfPage;
begin
  Result := False;
  URL := '';
  if FIsTextFile or not Assigned(FDocument) then Exit;
  for I := 0 to FPageCount - 1 do
  begin
    PR := PageScreenRect(I);
    if PR.Bottom < 0 then Continue;
    if PR.Top > Height then Break;
    Page := TPdfPage(FDocument.Pages[I]);
    for J := 0 to High(Page.LinkURLs) do
    begin
      if Page.LinkURLs[J] = '' then Continue;  // internal/non-URI link
      LR := PdfToScreen(I, Page.LinkRects[J]);
      if LR.Top > LR.Bottom then begin
        t := LR.Top;
        LR.Top := LR.Bottom;
        LR.Bottom := t;
      end;
      if (X >= LR.Left) and (X < LR.Right) and (Y >= LR.Top) and (Y < LR.Bottom) then
      begin
        URL := Page.LinkURLs[J];
        Exit(True);
      end;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Resize
// ---------------------------------------------------------------------------

procedure TXelPDF.Resize;
begin
  inherited;
  if Assigned(FScrollBar) then
    FScrollBar.SetBounds(Width - XELPDF_SCROLLBAR_W, 0, XELPDF_SCROLLBAR_W, Height);
  if FAutoFit <> afNone then
    ApplyAutoFit;  // rescale to the new component size
  if Length(FPageOffsets) > 0 then
    UpdateScrollBarRange;
  Invalidate;
end;

// ---------------------------------------------------------------------------
// Mouse
// ---------------------------------------------------------------------------

procedure TXelPDF.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
var URL: string;
begin
  inherited;
  if Button = mbLeft then
  begin
    SetFocus;
    // Ctrl+click on a hyperlink opens it in the default system browser instead
    // of starting a text selection.
    if (ssCtrl in Shift) and LinkAtPoint(X, Y, URL) then
    begin
      OpenURL(URL);
      Exit;
    end;
    FSelecting    := True;
    FHasSelection := False;
    FSelX1 := X;
    FSelY1 := Y;
    FSelX2 := X;
    FSelY2 := Y;
    Invalidate;
  end;
end;

procedure TXelPDF.MouseMove(Shift: TShiftState; X, Y: Integer);
var URL: string;
begin
  inherited;
  if FSelecting then
  begin
    FSelX2 := X;
    FSelY2 := Y;
    Invalidate;
  end
  else
  begin
    // Hand cursor over a hyperlink (hint that Ctrl+click follows it).
    if LinkAtPoint(X, Y, URL) then Cursor := crHandPoint else Cursor := crDefault;
  end;
end;

procedure TXelPDF.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  inherited;
  if Button = mbLeft then
  begin
    FSelX2        := X;
    FSelY2 := Y;
    FSelecting    := False;
    FHasSelection := (Abs(FSelX2 - FSelX1) > 3) or (Abs(FSelY2 - FSelY1) > 3);
    Invalidate;
  end;
end;

function TXelPDF.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  DoSetScrollPos(FScrollPos - (WheelDelta div 120) * 80);
  Result := True;
end;

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

procedure TXelPDF.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited;
  case Key of
    Ord('C'):
      if ssCtrl in Shift then
        CopySelectionToClipboard;
    VK_F3:
      if ssShift in Shift then SearchPrev else SearchNext;
    VK_NEXT  : DoSetScrollPos(FScrollPos + Max(1, Height - FPageSpacing));
    VK_PRIOR : DoSetScrollPos(FScrollPos - Max(1, Height - FPageSpacing));
    VK_DOWN  : DoSetScrollPos(FScrollPos + 40);
    VK_UP    : DoSetScrollPos(FScrollPos - 40);
    VK_HOME  : DoSetScrollPos(0);
    VK_END   : DoSetScrollPos(FTotalHeight);
  end;
end;

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

function TXelPDF.Search(const AText: string): Integer;
var
  PI, EI       : Integer;
  Page         : TPdfPage;
  Elem         : TPdfPageElement;
  TextElem     : TPdfTextElement;
  NeedleU, HaystackU : UnicodeString;
begin
  ClearSearch;
  if AText = '' then Exit(0);
  FSearchText := AText;
  NeedleU     := WideUpperCase(UTF8Decode(AText));

  for PI := 0 to FDocument.Pages.Count - 1 do
  begin
    Page := TPdfPage(FDocument.Pages[PI]);
    Page.EnsureParsed;
    for EI := 0 to Page.Elements.Count - 1 do
    begin
      Elem := TPdfPageElement(Page.Elements[EI]);
      if Elem.Kind <> pekText then Continue;
      TextElem   := TPdfTextElement(Elem);
      HaystackU  := WideUpperCase(TextElem.Text);
      if Pos(NeedleU, HaystackU) > 0 then
      begin
        SetLength(FSearchResults, FSearchResultCount + 1);
        FSearchResults[FSearchResultCount].PageIndex    := PI;
        FSearchResults[FSearchResultCount].ElementIndex := EI;
        FSearchResults[FSearchResultCount].Bounds       := TextElemApproxPdfRect(TextElem);
        Inc(FSearchResultCount);
      end;
    end;
  end;

  Result := FSearchResultCount;
  if FSearchResultCount > 0 then
  begin
    FCurrentResult := 0;
    ScrollToPage(FSearchResults[0].PageIndex);
  end;
  Invalidate;
end;

procedure TXelPDF.SearchNext;
begin
  if FSearchResultCount = 0 then Exit;
  FCurrentResult := (FCurrentResult + 1) mod FSearchResultCount;
  ScrollToPage(FSearchResults[FCurrentResult].PageIndex);
  Invalidate;
end;

procedure TXelPDF.SearchPrev;
begin
  if FSearchResultCount = 0 then Exit;
  FCurrentResult := (FCurrentResult - 1 + FSearchResultCount) mod FSearchResultCount;
  ScrollToPage(FSearchResults[FCurrentResult].PageIndex);
  Invalidate;
end;

procedure TXelPDF.ClearSearch;
begin
  FSearchText        := '';
  FSearchResultCount := 0;
  FCurrentResult     := -1;
  SetLength(FSearchResults, 0);
  Invalidate;
end;

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

function TXelPDF.GetSelectedText: string;
var
  PI, EI, CI : Integer;
  Page       : TPdfPage;
  Elem       : TPdfPageElement;
  TextElem   : TPdfTextElement;
  CharR      : TRect;
  Buf        : string;
  LastMidY   : Integer;
  MidY, H    : Integer;
begin
  Result := '';
  if not FHasSelection then Exit;
  if (Abs(FSelX2 - FSelX1) <= 2) and (Abs(FSelY2 - FSelY1) <= 2) then Exit;

  Buf      := '';
  LastMidY := -9999;

  for PI := 0 to FDocument.Pages.Count - 1 do
  begin
    Page := TPdfPage(FDocument.Pages[PI]);
    Page.EnsureParsed;
    for EI := 0 to Page.Elements.Count - 1 do
    begin
      Elem := TPdfPageElement(Page.Elements[EI]);
      if Elem.Kind <> pekText then Continue;
      TextElem := TPdfTextElement(Elem);
      for CI := 0 to Length(TextElem.Text) - 1 do
      begin
        if CI >= Length(TextElem.CharWidths) then Continue;
        CharR := PdfToScreen(PI, CharPdfRect(TextElem, CI));
        if not IsTextInSelection(CharR, FSelX1, FSelY1, FSelX2, FSelY2) then Continue;

        H    := Max(1, CharR.Bottom - CharR.Top);
        MidY := (CharR.Top + CharR.Bottom) div 2;
        // Insert a newline only when the Y-centre moves by more than half a
        // glyph height — i.e. we have crossed into a different text line.
        if (Buf <> '') and (Abs(MidY - LastMidY) > H div 2) then
          Buf := Buf + LineEnding;

        Buf      := Buf + UTF8Encode(UnicodeString(TextElem.Text[CI + 1]));
        LastMidY := MidY;
      end;
    end;
  end;
  Result := Buf;
end;

procedure TXelPDF.CopySelectionToClipboard;
var S: string;
begin
  S := GetSelectedText;
  if S <> '' then
    Clipboard.AsText := S;
end;

// ---------------------------------------------------------------------------
// Text file support
// ---------------------------------------------------------------------------

// Word-wrap one source line to at most MaxChars characters, breaking at the
// last space within the limit.  If no space is found the line is hard-broken.
// Appends all resulting wrapped lines to Dest.
procedure WrapAndAppend(const Line: string; MaxChars: Integer; Dest: TStrings);
var
  Rem : string;
  P   : Integer;
begin
  Rem := Line;
  while Length(Rem) > MaxChars do
  begin
    P := MaxChars;
    while (P > 1) and (Rem[P] <> ' ') do Dec(P);
    if P <= 1 then P := MaxChars;  // no space — hard break
    Dest.Add(TrimRight(Copy(Rem, 1, P)));
    Rem := TrimLeft(Copy(Rem, P + 1, MaxInt));
  end;
  Dest.Add(Rem);
end;

procedure TXelPDF.LoadText(const FileName: string);
// Read a .txt file, word-wrap to 80 chars, 50 lines per A4 page.
// Builds the document directly on a TPdfDocument — text selection, search
// and clipboard all work normally.
const
  PAGE_W         = 595.0;  // A4 width  in points
  PAGE_H         = 842.0;  // A4 height in points
  LINES_PER_PAGE = 50;
  MAX_CHARS      = 80;
  FONT_SIZE      = 10.0;
  LEADING        = 14.0;  // vertical distance between baselines
  MARGIN_L       = 50.0;  // left margin
  MARGIN_TOP     = 50.0;  // distance from top edge to first baseline
var
  SrcLines : TStringList;
  AllLines : TStringList;
  Doc      : TPdfDocument;
  MS       : TMemoryStream;
  FontRes  : AnsiString;
  I, LI    : Integer;
  PageCount: Integer;
  PageIdx  : Integer;
  LineY    : Double;
begin
  Doc      := nil;
  MS       := nil;
  SrcLines := TStringList.Create;
  AllLines := TStringList.Create;
  try
    // 1. Read and word-wrap
    SrcLines.LoadFromFile(FileName);
    for I := 0 to SrcLines.Count - 1 do
      WrapAndAppend(SrcLines[I], MAX_CHARS, AllLines);

    PageCount := (AllLines.Count + LINES_PER_PAGE - 1) div LINES_PER_PAGE;
    if PageCount < 1 then PageCount := 1;

    // 2. Build document via TPdfDocument
    Doc := TPdfDocument.Create(PAGE_W, PAGE_H);  // first page
    for I := 1 to PageCount - 1 do
      Doc.AddPage(PAGE_W, PAGE_H);  // remaining pages

    // 3. Register the font once; place every line as a separate text element
    FontRes := Doc.AddFont('Courier', FONT_SIZE);
    for LI := 0 to AllLines.Count - 1 do
    begin
      PageIdx := LI div LINES_PER_PAGE;
      LineY   := PAGE_H - MARGIN_TOP - (LI mod LINES_PER_PAGE) * LEADING;
      Doc.AddText(PageIdx, AllLines[LI], MARGIN_L, LineY, FontRes);
    end;

    // 4. Bake into a memory buffer and load — no temp file needed
    MS := TMemoryStream.Create;
    Doc.SaveToStream(MS);
    MS.Position := 0;

    FIsTextFile := False;
    FDocument.LoadFromStream(MS);
    LayoutPages;

  finally
    MS.Free;
    Doc.Free;
    AllLines.Free;
    SrcLines.Free;
  end;
end;

// Convert a Markdown file to a PDF (A4) and load it. Like LoadText, the document
// is built directly on a TPdfDocument so selection/search/copy all work.
procedure TXelPDF.LoadMarkdown(const FileName: string);
const PAGE_W = 595.0; PAGE_H = 842.0;
var Doc: TPdfDocument; MS: TMemoryStream; SL: TStringList;
begin
  Doc := nil; MS := nil; SL := TStringList.Create;
  try
    SL.LoadFromFile(FileName);              // raw bytes (UTF-8 folded later)
    Doc := TPdfDocument.Create(PAGE_W, PAGE_H);
    BuildPdfFromMarkdown(SL.Text, Doc);
    MS := TMemoryStream.Create;
    Doc.SaveToStream(MS);
    MS.Position := 0;
    FIsTextFile := False;
    FDocument.LoadFromStream(MS);
    LayoutPages;
  finally
    MS.Free; Doc.Free; SL.Free;
  end;
end;

// ---------------------------------------------------------------------------

procedure Register;
begin
  RegisterComponents('XelPDF', [TXelPDF]);
end;

end.
