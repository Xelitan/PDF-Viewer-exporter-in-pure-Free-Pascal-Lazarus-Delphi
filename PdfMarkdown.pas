unit PdfMarkdown;

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
// Markdown -> PDF. Parses a CommonMark-ish subset and lays it out onto a
//  TPdfDocument using the writer API (Create/AddPage/AddFont/AddText/DrawRect),
//  so the result is real selectable/searchable PDF text.
//
//  Supported: ATX headings (#..######), paragraphs with word wrap, inline **bold**
//  / *italic* / `code` / [links](url) (link text shown), bullet lists (-,*,+) and
//  ordered lists (1.) with nesting by indent, > blockquotes, fenced ``` code
//  blocks, --- horizontal rules, and automatic pagination. Text is laid out in
//  WinAnsi (UTF-8 input is folded to Latin-1), which covers typical documents. 

{$mode delphi}

interface

uses
  Classes, SysUtils, Graphics, PdfParser;

// Build the document from Markdown source (already-decoded text). Doc must be a
// freshly created TPdfDocument; this adds its pages/content.
procedure BuildPdfFromMarkdown(const MarkdownText: string; Doc: TPdfDocument);

implementation

const
  PAGE_W   = 595.0;   // A4 portrait, points
  PAGE_H   = 842.0;
  MARGIN   = 56.0;
  BODY_SZ  = 11.0;
  BODY_LEAD= 15.4;
  CODE_SZ  = 9.5;
  OVERSAMPLE = 4;     // measure at 4x size for sub-point precision (avoid clash with field Meas)

  // style flag bits (per character)
  fB = 1;             // bold
  fI = 2;             // italic
  fC = 4;             // code (monospace)

type
  TMdBuilder = class
  private
    Doc: TPdfDocument;
    Meas: TBitmap;
    PageIdx: Integer;
    CurY: Double;     // top of the next line, distance from the page top (points)

    procedure NewPage;
    procedure EnsureSpace(H: Double);
    procedure SetMeasFont(Flags: Byte; Size: Double);
    function  MeasureWidth(const S: string; Flags: Byte; Size: Double): Double;
    function  FontResFor(Flags: Byte; Size: Double): AnsiString;
    procedure PlaceText(const S: string; X, BaselineTop: Double; Flags: Byte; Size: Double);
    // Lay out styled text (text + per-char flags) as wrapped lines. MarkerText is
    // drawn once at the left of the first line (list bullet/number); TextIndent is
    // the hanging indent for all lines.
    procedure RenderStyled(const Text: string; const Flags: TBytes;
                           Size, Leading, LeftIndent, TextIndent, RightIndent: Double;
                           const MarkerText: string; MarkerFlags: Byte);
    procedure HorizontalRule;
    procedure GutterBar(TopY, BotY, X: Double);
  public
    constructor Create(ADoc: TPdfDocument);
    destructor Destroy; override;
    procedure Run(const Md: string);
  end;

// ── UTF-8 -> Latin-1 (best effort) so accents/smart-quotes render in WinAnsi ──
function Utf8ToLatin1(const S: string): string;
var i, n, cp: Integer; b: Byte;
begin
  Result := ''; i := 1; n := Length(S);
  while i <= n do
  begin
    b := Byte(S[i]);
    if b < $80 then begin Result := Result + Char(b); Inc(i); end
    else if (b and $E0) = $C0 then
    begin
      cp := ((b and $1F) shl 6); if i+1<=n then cp := cp or (Byte(S[i+1]) and $3F);
      Inc(i,2);
      if cp <= $FF then Result := Result + Char(cp) else Result := Result + '?';
    end
    else if (b and $F0) = $E0 then
    begin
      // 3-byte: map common typographic chars to Latin-1 look-alikes.
      cp := 0; if i+2<=n then cp := ((b and $0F) shl 12) or ((Byte(S[i+1]) and $3F) shl 6) or (Byte(S[i+2]) and $3F);
      Inc(i,3);
      case cp of
        $2018,$2019: Result := Result + '''';        // ‘ ’
        $201C,$201D: Result := Result + '"';          // “ ”
        $2013,$2014: Result := Result + '-';          // – —
        $2026:       Result := Result + '...';         // …
        $2022:       Result := Result + Char($95);     // • (WinAnsi bullet)
      else
        if cp <= $FF then Result := Result + Char(cp) else Result := Result + '?';
      end;
    end
    else begin Inc(i, 4); Result := Result + '?'; end;  // 4-byte (emoji etc.)
  end;
end;

constructor TMdBuilder.Create(ADoc: TPdfDocument);
begin
  inherited Create;
  Doc := ADoc;
  Meas := TBitmap.Create;
  Meas.SetSize(8, 8);
  PageIdx := 0;
  CurY := MARGIN;
end;

destructor TMdBuilder.Destroy;
begin
  Meas.Free;
  inherited Destroy;
end;

procedure TMdBuilder.NewPage;
begin
  Doc.AddPage(PAGE_W, PAGE_H);
  Inc(PageIdx);
  CurY := MARGIN;
end;

procedure TMdBuilder.EnsureSpace(H: Double);
begin
  if CurY + H > PAGE_H - MARGIN then NewPage;
end;

procedure TMdBuilder.SetMeasFont(Flags: Byte; Size: Double);
var st: TFontStyles;
begin
  if (Flags and fC) <> 0 then Meas.Canvas.Font.Name := 'Consolas'
  else Meas.Canvas.Font.Name := 'Arial';
  st := [];
  if (Flags and fB) <> 0 then Include(st, fsBold);
  if (Flags and fI) <> 0 then Include(st, fsItalic);
  Meas.Canvas.Font.Style := st;
  Meas.Canvas.Font.Height := -Round(Size * OVERSAMPLE);
end;

function TMdBuilder.MeasureWidth(const S: string; Flags: Byte; Size: Double): Double;
begin
  if S = '' then Exit(0);
  SetMeasFont(Flags, Size);
  Result := Meas.Canvas.TextWidth(S) / OVERSAMPLE;
end;

function TMdBuilder.FontResFor(Flags: Byte; Size: Double): AnsiString;
var nm: string;
begin
  if (Flags and fC) <> 0 then
  begin
    if (Flags and fB) <> 0 then nm := 'Courier-Bold' else nm := 'Courier';
  end
  else if (Flags and (fB or fI)) = (fB or fI) then nm := 'Helvetica-BoldOblique'
  else if (Flags and fB) <> 0 then nm := 'Helvetica-Bold'
  else if (Flags and fI) <> 0 then nm := 'Helvetica-Oblique'
  else nm := 'Helvetica';
  Result := Doc.AddFont(nm, Size);
end;

procedure TMdBuilder.PlaceText(const S: string; X, BaselineTop: Double; Flags: Byte; Size: Double);
begin
  if Trim(S) = '' then Exit;
  Doc.AddText(PageIdx, S, X, PAGE_H - BaselineTop, FontResFor(Flags, Size));
end;

procedure TMdBuilder.HorizontalRule;
begin
  EnsureSpace(BODY_LEAD);
  CurY := CurY + BODY_LEAD * 0.5;
  Doc.DrawRect(PageIdx, MARGIN, PAGE_H - CurY, PAGE_W - 2*MARGIN, 0.8, clSilver);
  CurY := CurY + BODY_LEAD * 0.5;
end;

procedure TMdBuilder.GutterBar(TopY, BotY, X: Double);
begin
  if BotY > TopY then
    Doc.DrawRect(PageIdx, X, PAGE_H - BotY, 2.5, BotY - TopY, clSilver);
end;

// Lay out styled text into wrapped lines. Words are whitespace-separated; each
// word may contain multiple style segments (e.g. a **bold** word touching plain
// text), placed left to right with per-segment fonts.
procedure TMdBuilder.RenderStyled(const Text: string; const Flags: TBytes;
  Size, Leading, LeftIndent, TextIndent, RightIndent: Double;
  const MarkerText: string; MarkerFlags: Byte);
var
  n, i, wStart, segStart, k: Integer;
  rightLimit, x, baseTop, ascent, wordW, spW, segW: Double;
  firstLineOfBlock, lineStarted, markerPending: Boolean;

  procedure StartLine;
  begin
    EnsureSpace(Leading);
    x := MARGIN + TextIndent;
    baseTop := CurY + Size * 0.8;
    ascent := Size * 0.8;
    if markerPending then
    begin
      PlaceText(MarkerText, MARGIN + LeftIndent, baseTop, MarkerFlags, Size);
      markerPending := False;
    end;
    lineStarted := True;
  end;

  procedure EndLine;
  begin
    CurY := CurY + Leading;
    lineStarted := False;
  end;

begin
  n := Length(Text);
  rightLimit := PAGE_W - MARGIN - RightIndent;
  spW := MeasureWidth(' ', 0, Size);
  firstLineOfBlock := True;
  markerPending := MarkerText <> '';
  lineStarted := False;
  if ascent = 0 then ; // silence hint
  baseTop := 0;

  i := 1;
  while i <= n do
  begin
    // skip run of spaces between words
    if Text[i] = ' ' then begin Inc(i); Continue; end;
    // a word = consecutive non-space chars
    wStart := i;
    while (i <= n) and (Text[i] <> ' ') do Inc(i);
    // measure the whole word (sum of style segments)
    wordW := 0;
    k := wStart;
    while k < i do
    begin
      segStart := k;
      while (k < i) and (Flags[k-1] = Flags[segStart-1]) do Inc(k);
      wordW := wordW + MeasureWidth(Copy(Text, segStart, k - segStart), Flags[segStart-1], Size);
    end;

    if not lineStarted then StartLine;
    // wrap if this word won't fit (and the line already has content)
    if (x > MARGIN + TextIndent + 0.01) and (x + spW + wordW > rightLimit) then
    begin
      EndLine;
      StartLine;
    end
    else if x > MARGIN + TextIndent + 0.01 then
      x := x + spW;   // inter-word space

    // place the word's style segments
    k := wStart;
    while k < i do
    begin
      segStart := k;
      while (k < i) and (Flags[k-1] = Flags[segStart-1]) do Inc(k);
      segW := MeasureWidth(Copy(Text, segStart, k - segStart), Flags[segStart-1], Size);
      PlaceText(Copy(Text, segStart, k - segStart), x, baseTop, Flags[segStart-1], Size);
      x := x + segW;
    end;
    firstLineOfBlock := False;
  end;

  if lineStarted then EndLine
  else if markerPending then
  begin
    // marker-only line (e.g. empty list item)
    StartLine; EndLine;
  end;
  if firstLineOfBlock and not lineStarted then ;  // nothing emitted
end;

// ── inline markdown -> (text, per-char style flags) ──
procedure ParseInline(const S: string; ExtraFlags: Byte; out OutText: string; out OutFlags: TBytes);
var
  i, n, j, depth: Integer;
  bold, ital: Boolean;
  cur: Byte;
  sb: string;
  flags: array of Byte;
  cnt: Integer;

  // NB: flags is pre-sized to the input length (output is never longer than the
  // input) so Emit never SetLengths inside this nested proc — growing an outer
  // dynamic array from a nested procedure corrupts the FPC i386 stack frame.
  procedure Emit(c: Char; f: Byte);
  begin
    sb := sb + c;
    flags[cnt] := f or ExtraFlags;
    Inc(cnt);
  end;

begin
  n := Length(S); i := 1; bold := False; ital := False; sb := ''; cnt := 0;
  SetLength(flags, n + 1);
  while i <= n do
  begin
    cur := 0;
    if bold then cur := cur or fB;
    if ital then cur := cur or fI;

    // escape
    if (S[i] = '\') and (i < n) then begin Emit(S[i+1], cur); Inc(i, 2); Continue; end;
    // inline code
    if S[i] = '`' then
    begin
      Inc(i);
      while (i <= n) and (S[i] <> '`') do begin Emit(S[i], fC); Inc(i); end;
      if i <= n then Inc(i);
      Continue;
    end;
    // image ![alt](src) -> alt ; link [text](url) -> text
    if ((S[i] = '!') and (i < n) and (S[i+1] = '[')) or (S[i] = '[') then
    begin
      if S[i] = '!' then Inc(i);          // skip '!'
      // find matching ']'
      j := i + 1; depth := 1;
      while (j <= n) and (depth > 0) do
      begin
        if S[j] = '[' then Inc(depth)
        else if S[j] = ']' then Dec(depth);
        if depth = 0 then Break;
        Inc(j);
      end;
      if (j <= n) and (j < n) and (S[j] = ']') and (S[j+1] = '(') then
      begin
        // emit the link/alt text (between i+1 and j-1) with current style
        for depth := i + 1 to j - 1 do Emit(S[depth], cur);
        // skip the (url) part
        i := j + 2;
        while (i <= n) and (S[i] <> ')') do Inc(i);
        if i <= n then Inc(i);
        Continue;
      end
      else begin Emit('[', cur); Inc(i); Continue; end;
    end;
    // emphasis
    if (S[i] = '*') or (S[i] = '_') then
    begin
      if (i < n) and (S[i+1] = S[i]) then begin bold := not bold; Inc(i, 2); Continue; end
      else begin ital := not ital; Inc(i); Continue; end;
    end;
    Emit(S[i], cur);
    Inc(i);
  end;
  OutText := sb;
  SetLength(OutFlags, cnt);
  for i := 0 to cnt - 1 do OutFlags[i] := flags[i];
end;

procedure TMdBuilder.Run(const Md: string);
var
  Lines: TStringList;
  li, level, num: Integer;
  raw, t, txt, body, fence: string;   // body = ParseInline output (never aliased with its input)
  flg: TBytes;
  hsize, hlead: Double;
  leadSpaces, indentLevel: Integer;
  marker: string;
  blockTop: Double;
  i2: Integer;

  function CountLeading(const s: string): Integer;
  begin Result := 0; while (Result < Length(s)) and (s[Result+1] = ' ') do Inc(Result); end;

  function IsFence(const s: string): Boolean;
  var tt: string;
  begin tt := TrimLeft(s); Result := (Copy(tt,1,3) = '```') or (Copy(tt,1,3) = '~~~'); end;

  function IsHRule(const s: string): Boolean;
  var tt: string; c: Char; k, cc: Integer;
  begin
    tt := StringReplace(Trim(s), ' ', '', [rfReplaceAll]);
    Result := False;
    if Length(tt) < 3 then Exit;
    c := tt[1];
    if not (c in ['-','*','_']) then Exit;
    cc := 0;
    for k := 1 to Length(tt) do begin if tt[k] <> c then Exit; Inc(cc); end;
    Result := cc >= 3;
  end;

begin
  Lines := TStringList.Create;
  try
    Lines.Text := Md;
    li := 0;
    while li < Lines.Count do
    begin
      raw := Lines[li];
      t := TrimRight(raw);

      // blank line -> paragraph gap
      if Trim(t) = '' then begin CurY := CurY + BODY_LEAD * 0.5; Inc(li); Continue; end;

      // fenced code block
      if IsFence(t) then
      begin
        fence := Copy(TrimLeft(t), 1, 3);
        Inc(li);
        blockTop := CurY;
        while (li < Lines.Count) and not (Copy(TrimLeft(Lines[li]),1,3) = fence) do
        begin
          txt := Utf8ToLatin1(Lines[li]);
          SetLength(flg, Length(txt));
          for i2 := 0 to High(flg) do flg[i2] := fC;
          EnsureSpace(CODE_SZ * 1.35);
          if Length(txt) = 0 then CurY := CurY + CODE_SZ * 1.35   // blank code line
          else RenderStyled(txt, flg, CODE_SZ, CODE_SZ * 1.35, 14, 14, 0, '', 0);
          Inc(li);                                                 // advance — else infinite loop
        end;
        GutterBar(blockTop, CurY, MARGIN + 6);
        if li < Lines.Count then Inc(li);  // skip closing fence
        CurY := CurY + BODY_LEAD * 0.4;
        Continue;
      end;

      // horizontal rule
      if IsHRule(t) then begin HorizontalRule; Inc(li); Continue; end;

      // heading
      if (Length(TrimLeft(t)) > 0) and (TrimLeft(t)[1] = '#') then
      begin
        t := TrimLeft(t);
        level := 0;
        while (level < Length(t)) and (t[level+1] = '#') do Inc(level);
        if (level >= 1) and (level <= 6) and (level < Length(t)) and (t[level+1] = ' ') then
        begin
          case level of
            1: hsize := 24; 2: hsize := 19; 3: hsize := 15;
            4: hsize := 13; 5: hsize := 12; else hsize := 11;
          end;
          hlead := hsize * 1.3;
          CurY := CurY + hsize * 0.35;   // space above heading
          ParseInline(Utf8ToLatin1(Trim(Copy(t, level + 1, MaxInt))), fB, txt, flg);
          RenderStyled(txt, flg, hsize, hlead, 0, 0, 0, '', 0);
          CurY := CurY + hsize * 0.2;
          Inc(li);
          Continue;
        end;
      end;

      // blockquote
      if (Length(TrimLeft(t)) > 0) and (TrimLeft(t)[1] = '>') then
      begin
        blockTop := CurY;
        while (li < Lines.Count) and (Length(TrimLeft(TrimRight(Lines[li]))) > 0)
              and (TrimLeft(TrimRight(Lines[li]))[1] = '>') do
        begin
          t := TrimLeft(TrimRight(Lines[li]));
          Delete(t, 1, 1);                 // drop '>'
          if (Length(t) > 0) and (t[1] = ' ') then Delete(t, 1, 1);
          ParseInline(Utf8ToLatin1(t), fI, txt, flg);
          RenderStyled(txt, flg, BODY_SZ, BODY_LEAD, 16, 16, 0, '', 0);
          Inc(li);
        end;
        GutterBar(blockTop, CurY, MARGIN + 4);
        CurY := CurY + BODY_LEAD * 0.3;
        Continue;
      end;

      // list item (unordered - * +  or ordered 1. )
      leadSpaces := CountLeading(raw);
      t := TrimLeft(t);
      if ((Length(t) >= 2) and (t[1] in ['-','*','+']) and (t[2] = ' ')) or
         ((Length(t) >= 3) and (t[1] in ['0'..'9'])) then
      begin
        // ordered?
        num := 0; i2 := 1;
        while (i2 <= Length(t)) and (t[i2] in ['0'..'9']) do begin num := num*10 + (Ord(t[i2])-48); Inc(i2); end;
        indentLevel := leadSpaces div 2;
        if (t[1] in ['-','*','+']) and (t[2] = ' ') then
        begin
          marker := Char($95) + '';                 // bullet (WinAnsi •)
          txt := Trim(Copy(t, 3, MaxInt));
        end
        else if (i2 <= Length(t)) and (t[i2] = '.') and (i2 < Length(t)) and (t[i2+1] = ' ') then
        begin
          marker := IntToStr(num) + '.';
          txt := Trim(Copy(t, i2 + 2, MaxInt));
        end
        else
        begin
          marker := '';
          txt := t;
        end;
        if marker <> '' then
        begin
          ParseInline(Utf8ToLatin1(txt), 0, body, flg);
          RenderStyled(body, flg, BODY_SZ, BODY_LEAD,
                       12 + indentLevel * 16, 12 + indentLevel * 16 + 16, 0, marker, 0);
          Inc(li);
          Continue;
        end;
      end;

      // paragraph: gather consecutive plain lines
      txt := raw;
      Inc(li);
      while (li < Lines.Count) do
      begin
        t := TrimRight(Lines[li]);
        if (Trim(t) = '') or IsFence(t) or IsHRule(t) then Break;
        t := TrimLeft(t);
        if (Length(t) > 0) and (t[1] in ['#','>']) then Break;
        if ((Length(t) >= 2) and (t[1] in ['-','*','+']) and (t[2] = ' ')) then Break;
        txt := txt + ' ' + Lines[li];
        Inc(li);
      end;
      ParseInline(Utf8ToLatin1(txt), 0, body, flg);
      RenderStyled(body, flg, BODY_SZ, BODY_LEAD, 0, 0, 0, '', 0);
      CurY := CurY + BODY_LEAD * 0.35;   // paragraph spacing
    end;
  finally
    Lines.Free;
  end;
end;

procedure BuildPdfFromMarkdown(const MarkdownText: string; Doc: TPdfDocument);
var b: TMdBuilder;
begin
  b := TMdBuilder.Create(Doc);
  try
    b.Run(MarkdownText);
  finally
    b.Free;
  end;
end;

end.
