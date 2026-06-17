unit PdfFonts;
{$mode delphi}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
interface

uses
  SysUtils, Classes, Contnrs, PdfTypes, PdfObjects, PdfCMap;

type
  TPdfGlyphWidth = record
    Code: Integer;
    Width: Double;
  end;

  TPdfFontProgramKind = (fpkNone, fpkType1, fpkCFF, fpkTrueType, fpkUnknown);

  TPdfFont = class
  private
    FCMap: TPdfCMap;
    FDifferences: TStringList;  // object name: code -> glyph name
    FEncoding: TStringList;  // object name: code -> glyph name
    FWidths: array of TPdfGlyphWidth;  // simple-font widths by character code
    FCIDWidths: array of TPdfGlyphWidth;  // CID widths from W array
    FDefaultWidth: Double;
    FDefaultVerticalWidth: Double;
    FVertical: Boolean;
    FFontProgramKind: TPdfFontProgramKind;
    FFontProgramLength: Integer;
    FCIDRegistry: string;
    FCIDOrdering: string;
    FCIDSupplement: Integer;
    FFontProgram: TPdfBytes;

    procedure BuildStandardEncoding(const EncName: string);
    procedure LoadEncoding(EncodingObj: TPdfObject);
    procedure LoadDifferences(DiffObj: TPdfObject);
    procedure LoadDescendantFont(DescFontsObj: TPdfObject);
    procedure LoadFontDescriptor(DescriptorObj: TPdfObject);
    procedure LoadCIDSystemInfo(SysInfoObj: TPdfObject);

    function GlyphNameForCode(Code: Integer): string;
    function GlyphNameToUnicode(const GlyphName: string): UnicodeString;
    function DecodeSimpleByte(B: Byte): UnicodeString;
    function DecodeCIDString(const S: AnsiString): UnicodeString;
    procedure SetWidth(var Arr: array of TPdfGlyphWidth; Code: Integer; Width: Double);
    function GetWidthFrom(const Arr: array of TPdfGlyphWidth; Code: Integer; Default: Double): Double;
  public
    BaseFont: string;
    Subtype: string;
    EncodingName: string;
    // Type3 font state (Subtype /Type3): glyphs are arbitrary content streams
    // (CharProcs) drawn in glyph space mapped through Type3Matrix. The parser
    // fills these and renders each glyph by interpreting its CharProc.
    IsType3: Boolean;
    Type3Matrix: TPdfMatrix;                 // /FontMatrix (glyph space -> text space)
    Type3CharProcs: TPdfDictionaryObject;    // glyph name -> CharProc stream (ref, not owned)
    Type3Resources: TPdfDictionaryObject;    // resources for the CharProc streams (ref)

    constructor Create;
    destructor Destroy;
    override;

    procedure LoadFromDictionary(FontDict: TPdfDictionaryObject; ResolveProc: Pointer);
    // Public so callers can reload widths after resolving indirect references.
    procedure LoadWidths(WidthsObj: TPdfObject; FirstChar: Integer);
    // Public so the parser can attach the embedded program after resolving the
    // (indirect) FontDescriptor and FontFile streams itself.
    procedure SetFontProgramBytes(AKind: TPdfFontProgramKind; const Data: TPdfBytes);
    // Public so the parser can load CID metrics after resolving the (indirect)
    // descendant font, its /W array and /DW default.
    procedure LoadCIDWidths(WObj: TPdfObject);
    procedure SetDefaultWidth(W: Double);
    function IsCIDFont: Boolean;
    procedure SetToUnicode(CMap: TPdfCMap);
    function DecodeString(const S: AnsiString): UnicodeString;
    virtual;

    function WidthOfCode(Code: Integer): Double;
    function IsVerticalWriting: Boolean;
    // Glyph name for a character code (from /Encoding /Differences) — needed to
    // look up the right CharProc for a Type3 glyph.
    function GlyphName(Code: Integer): string;

    property CIDRegistry: string read FCIDRegistry;
    property CIDOrdering: string read FCIDOrdering;
    property CIDSupplement: Integer read FCIDSupplement;
    property FontProgramKind: TPdfFontProgramKind read FFontProgramKind;
    property FontProgramLength: Integer read FFontProgramLength;
    property FontProgram: TPdfBytes read FFontProgram;
    property DefaultWidth: Double read FDefaultWidth;
    property DefaultVerticalWidth: Double read FDefaultVerticalWidth;
  end;

implementation

function ObjName(const O: TPdfObject): string;
begin
  if Assigned(O) then Result := O.AsName else Result := '';
end;

function ObjNumber(const O: TPdfObject; Default: Double = 0): Double;
begin
  if Assigned(O) then Result := O.AsNumber else Result := Default;
end;

function IsType0Font(const S: string): Boolean;
begin
  Result := SameText(S, 'Type0');
end;

function IsVerticalCMapName(const S: string): Boolean;
begin
  Result := (Length(S) >= 2) and SameText(Copy(S, Length(S) - 1, 2), '-V');
end;

constructor TPdfFont.Create;
begin
  inherited Create;
  FCMap := nil;
  FDifferences := TStringList.Create;
  FDifferences.NameValueSeparator := '=';
  FEncoding := TStringList.Create;
  FEncoding.NameValueSeparator := '=';
  FDefaultWidth := 1000;
  FDefaultVerticalWidth := 1000;
  FCIDSupplement := -1;
  FFontProgramKind := fpkNone;
end;

destructor TPdfFont.Destroy;
begin
  FCMap.Free;
  FDifferences.Free;
  FEncoding.Free;
  inherited Destroy;
end;

procedure TPdfFont.SetWidth(var Arr: array of TPdfGlyphWidth; Code: Integer; Width: Double);
var
  I: Integer;
begin
  for I := Low(Arr) to High(Arr) do
    if Arr[I].Code = Code then
    begin
      Arr[I].Width := Width;
      Exit;
    end;
end;

function TPdfFont.GetWidthFrom(const Arr: array of TPdfGlyphWidth; Code: Integer; Default: Double): Double;
var
  I: Integer;
begin
  for I := Low(Arr) to High(Arr) do
    if Arr[I].Code = Code then
      Exit(Arr[I].Width);
  Result := Default;
end;

procedure TPdfFont.BuildStandardEncoding(const EncName: string);

  procedure Put(Code: Integer; const Name: string);
  begin
    FEncoding.Values[IntToStr(Code)] := Name;
  end;

var
  I: Integer;
begin
  FEncoding.Clear;

  // ASCII-compatible base. This is enough for many simple PDF fonts and is
  // then refined below for WinAnsi/MacRoman/PDFDoc special positions.
  for I := 32 to 126 do
    Put(I, Chr(I));

  Put(32, 'space');
  Put(33, 'exclam');
  Put(34, 'quotedbl');
  Put(35, 'numbersign');
  Put(36, 'dollar');
  Put(37, 'percent');
  Put(38, 'ampersand');
  Put(39, 'quotesingle');
  Put(40, 'parenleft');
  Put(41, 'parenright');
  Put(42, 'asterisk');
  Put(43, 'plus');
  Put(44, 'comma');
  Put(45, 'hyphen');
  Put(46, 'period');
  Put(47, 'slash');
  Put(58, 'colon');
  Put(59, 'semicolon');
  Put(60, 'less');
  Put(61, 'equal');
  Put(62, 'greater');
  Put(63, 'question');
  Put(64, 'at');
  Put(91, 'bracketleft');
  Put(92, 'backslash');
  Put(93, 'bracketright');
  Put(94, 'asciicircum');
  Put(95, 'underscore');
  Put(96, 'grave');
  Put(123, 'braceleft');
  Put(124, 'bar');
  Put(125, 'braceright');
  Put(126, 'asciitilde');

  // Frequently used WinAnsi/PDFDocEncoding high bytes.
  if SameText(EncName, 'WinAnsiEncoding') or SameText(EncName, 'PDFDocEncoding') or (EncName = '') then
  begin
    Put($80, 'Euro');
    Put($82, 'quotesinglbase');
    Put($83, 'florin');
    Put($84, 'quotedblbase');
    Put($85, 'ellipsis');
    Put($86, 'dagger');
    Put($87, 'daggerdbl');
    Put($88, 'circumflex');
    Put($89, 'perthousand');
    Put($8A, 'Scaron');
    Put($8B, 'guilsinglleft');
    Put($8C, 'OE');
    Put($8E, 'Zcaron');
    Put($91, 'quoteleft');
    Put($92, 'quoteright');
    Put($93, 'quotedblleft');
    Put($94, 'quotedblright');
    Put($95, 'bullet');
    Put($96, 'endash');
    Put($97, 'emdash');
    Put($98, 'tilde');
    Put($99, 'trademark');
    Put($9A, 'scaron');
    Put($9B, 'guilsinglright');
    Put($9C, 'oe');
    Put($9E, 'zcaron');
    Put($9F, 'Ydieresis');
    Put($A0, 'space');
    Put($A1, 'exclamdown');
    Put($A2, 'cent');
    Put($A3, 'sterling');
    Put($A4, 'currency');
    Put($A5, 'yen');
    Put($A6, 'brokenbar');
    Put($A7, 'section');
    Put($A8, 'dieresis');
    Put($A9, 'copyright');
    Put($AA, 'ordfeminine');
    Put($AB, 'guillemotleft');
    Put($AC, 'logicalnot');
    Put($AD, 'hyphen');
    Put($AE, 'registered');
    Put($AF, 'macron');
    Put($B0, 'degree');
    Put($B1, 'plusminus');
    Put($B2, 'twosuperior');
    Put($B3, 'threesuperior');
    Put($B4, 'acute');
    Put($B5, 'mu');
    Put($B6, 'paragraph');
    Put($B7, 'periodcentered');
    Put($B8, 'cedilla');
    Put($B9, 'onesuperior');
    Put($BA, 'ordmasculine');
    Put($BB, 'guillemotright');
    Put($BC, 'onequarter');
    Put($BD, 'onehalf');
    Put($BE, 'threequarters');
    Put($BF, 'questiondown');
    Put($C0, 'Agrave');
    Put($C1, 'Aacute');
    Put($C2, 'Acircumflex');
    Put($C3, 'Atilde');
    Put($C4, 'Adieresis');
    Put($C5, 'Aring');
    Put($C6, 'AE');
    Put($C7, 'Ccedilla');
    Put($C8, 'Egrave');
    Put($C9, 'Eacute');
    Put($CA, 'Ecircumflex');
    Put($CB, 'Edieresis');
    Put($CC, 'Igrave');
    Put($CD, 'Iacute');
    Put($CE, 'Icircumflex');
    Put($CF, 'Idieresis');
    Put($D0, 'Eth');
    Put($D1, 'Ntilde');
    Put($D2, 'Ograve');
    Put($D3, 'Oacute');
    Put($D4, 'Ocircumflex');
    Put($D5, 'Otilde');
    Put($D6, 'Odieresis');
    Put($D7, 'multiply');
    Put($D8, 'Oslash');
    Put($D9, 'Ugrave');
    Put($DA, 'Uacute');
    Put($DB, 'Ucircumflex');
    Put($DC, 'Udieresis');
    Put($DD, 'Yacute');
    Put($DE, 'Thorn');
    Put($DF, 'germandbls');
    Put($E0, 'agrave');
    Put($E1, 'aacute');
    Put($E2, 'acircumflex');
    Put($E3, 'atilde');
    Put($E4, 'adieresis');
    Put($E5, 'aring');
    Put($E6, 'ae');
    Put($E7, 'ccedilla');
    Put($E8, 'egrave');
    Put($E9, 'eacute');
    Put($EA, 'ecircumflex');
    Put($EB, 'edieresis');
    Put($EC, 'igrave');
    Put($ED, 'iacute');
    Put($EE, 'icircumflex');
    Put($EF, 'idieresis');
    Put($F0, 'eth');
    Put($F1, 'ntilde');
    Put($F2, 'ograve');
    Put($F3, 'oacute');
    Put($F4, 'ocircumflex');
    Put($F5, 'otilde');
    Put($F6, 'odieresis');
    Put($F7, 'divide');
    Put($F8, 'oslash');
    Put($F9, 'ugrave');
    Put($FA, 'uacute');
    Put($FB, 'ucircumflex');
    Put($FC, 'udieresis');
    Put($FD, 'yacute');
    Put($FE, 'thorn');
    Put($FF, 'ydieresis');
  end;
end;

procedure TPdfFont.LoadDifferences(DiffObj: TPdfObject);
var
  Arr: TPdfArrayObject;
  I, Code: Integer;
  O: TPdfObject;
begin
  FDifferences.Clear;
  if not (DiffObj is TPdfArrayObject) then Exit;
  Arr := TPdfArrayObject(DiffObj);
  Code := -1;
  for I := 0 to Arr.Items.Count - 1 do
  begin
    O := TPdfObject(Arr.Items[I]);
    if O.Kind in [pokInteger, pokReal] then
      Code := Trunc(O.AsNumber)
    else if O.Kind = pokName then
    begin
      if Code >= 0 then
      begin
        FDifferences.Values[IntToStr(Code)] := O.AsName;
        Inc(Code);
      end;
    end;
  end;
end;

procedure TPdfFont.LoadEncoding(EncodingObj: TPdfObject);
var
  EncDict: TPdfDictionaryObject;
  Base: string;
begin
  EncodingName := '';
  BuildStandardEncoding('WinAnsiEncoding');

  if not Assigned(EncodingObj) then Exit;

  if EncodingObj.Kind = pokName then
  begin
    EncodingName := EncodingObj.AsName;
    BuildStandardEncoding(EncodingName);
  end
  else if EncodingObj is TPdfDictionaryObject then
  begin
    EncDict := TPdfDictionaryObject(EncodingObj);
    Base := EncDict.GetName('BaseEncoding');
    if Base = '' then Base := 'WinAnsiEncoding';
    EncodingName := Base;
    BuildStandardEncoding(Base);
    LoadDifferences(EncDict.Get('Differences'));
  end;
end;

procedure TPdfFont.LoadWidths(WidthsObj: TPdfObject; FirstChar: Integer);
var
  Arr: TPdfArrayObject;
  I: Integer;
begin
  SetLength(FWidths, 0);
  if not (WidthsObj is TPdfArrayObject) then Exit;
  Arr := TPdfArrayObject(WidthsObj);
  SetLength(FWidths, Arr.Items.Count);
  for I := 0 to Arr.Items.Count - 1 do
  begin
    FWidths[I].Code := FirstChar + I;
    FWidths[I].Width := TPdfObject(Arr.Items[I]).AsNumber;
  end;
end;

procedure TPdfFont.LoadCIDWidths(WObj: TPdfObject);
var
  Arr, WidthArr: TPdfArrayObject;
  I, J, C1, C2, Count, OutIndex: Integer;
  O: TPdfObject;
begin
  SetLength(FCIDWidths, 0);
  if not (WObj is TPdfArrayObject) then Exit;
  Arr := TPdfArrayObject(WObj);

  Count := 0;
  I := 0;
  while I < Arr.Items.Count do
  begin
    if I + 1 >= Arr.Items.Count then Break;
    C1 := Trunc(TPdfObject(Arr.Items[I]).AsNumber);
    O := TPdfObject(Arr.Items[I + 1]);
    if O is TPdfArrayObject then
    begin
      Inc(Count, TPdfArrayObject(O).Items.Count);
      Inc(I, 2);
    end
    else
    begin
      if I + 2 >= Arr.Items.Count then Break;
      C2 := Trunc(O.AsNumber);
      Inc(Count, C2 - C1 + 1);
      Inc(I, 3);
    end;
  end;

  SetLength(FCIDWidths, Count);
  OutIndex := 0;
  I := 0;
  while I < Arr.Items.Count do
  begin
    if I + 1 >= Arr.Items.Count then Break;
    C1 := Trunc(TPdfObject(Arr.Items[I]).AsNumber);
    O := TPdfObject(Arr.Items[I + 1]);
    if O is TPdfArrayObject then
    begin
      WidthArr := TPdfArrayObject(O);
      for J := 0 to WidthArr.Items.Count - 1 do
      begin
        FCIDWidths[OutIndex].Code := C1 + J;
        FCIDWidths[OutIndex].Width := TPdfObject(WidthArr.Items[J]).AsNumber;
        Inc(OutIndex);
      end;
      Inc(I, 2);
    end
    else
    begin
      if I + 2 >= Arr.Items.Count then Break;
      C2 := Trunc(O.AsNumber);
      for J := C1 to C2 do
      begin
        FCIDWidths[OutIndex].Code := J;
        FCIDWidths[OutIndex].Width := TPdfObject(Arr.Items[I + 2]).AsNumber;
        Inc(OutIndex);
      end;
      Inc(I, 3);
    end;
  end;
end;

procedure TPdfFont.LoadCIDSystemInfo(SysInfoObj: TPdfObject);
var
  D: TPdfDictionaryObject;
begin
  if not (SysInfoObj is TPdfDictionaryObject) then Exit;
  D := TPdfDictionaryObject(SysInfoObj);
  if Assigned(D.Get('Registry')) then FCIDRegistry := string(D.Get('Registry').AsString);
  if Assigned(D.Get('Ordering')) then FCIDOrdering := string(D.Get('Ordering').AsString);
  if Assigned(D.Get('Supplement')) then FCIDSupplement := Trunc(D.Get('Supplement').AsNumber);
end;

procedure TPdfFont.SetFontProgramBytes(AKind: TPdfFontProgramKind; const Data: TPdfBytes);
begin
  FFontProgramKind := AKind;
  FFontProgram := Data;
  FFontProgramLength := Length(Data);
end;

procedure TPdfFont.SetDefaultWidth(W: Double);
begin
  if W > 0 then FDefaultWidth := W;
end;

function TPdfFont.IsCIDFont: Boolean;
begin
  Result := IsType0Font(Subtype);
end;

procedure TPdfFont.LoadFontDescriptor(DescriptorObj: TPdfObject);
var
  D: TPdfDictionaryObject;
  S: TPdfObject;
begin
  if not (DescriptorObj is TPdfDictionaryObject) then Exit;
  D := TPdfDictionaryObject(DescriptorObj);

  S := D.Get('FontFile');
  if S is TPdfStreamObject then
  begin
    FFontProgramKind := fpkType1;
    FFontProgramLength := Length(TPdfStreamObject(S).DecodedData);
  end;

  S := D.Get('FontFile2');
  if S is TPdfStreamObject then
  begin
    FFontProgramKind := fpkTrueType;
    FFontProgram := TPdfStreamObject(S).DecodedData;
    FFontProgramLength := Length(FFontProgram);
  end;

  S := D.Get('FontFile3');
  if S is TPdfStreamObject then
  begin
    if SameText(TPdfDictionaryObject(S).GetName('Subtype'), 'Type1C') or
       SameText(TPdfDictionaryObject(S).GetName('Subtype'), 'CIDFontType0C') or
       SameText(TPdfDictionaryObject(S).GetName('Subtype'), 'OpenType') then
    begin
      FFontProgramKind := fpkCFF;
      // Store the CFF program so the renderer can wrap it in an OTF and load it
      // into GDI (PdfCFF.WrapCFFToOTF). OpenType FontFile3 is already an SFNT.
      FFontProgram := TPdfStreamObject(S).DecodedData;
    end
    else
      FFontProgramKind := fpkUnknown;
    FFontProgramLength := Length(TPdfStreamObject(S).DecodedData);
  end;
end;

procedure TPdfFont.LoadDescendantFont(DescFontsObj: TPdfObject);
var
  Arr: TPdfArrayObject;
  Desc: TPdfObject;
  D: TPdfDictionaryObject;
begin
  if DescFontsObj is TPdfArrayObject then
  begin
    Arr := TPdfArrayObject(DescFontsObj);
    if Arr.Items.Count = 0 then Exit;
    Desc := TPdfObject(Arr.Items[0]);
  end
  else
    Desc := DescFontsObj;

  if not (Desc is TPdfDictionaryObject) then Exit;
  D := TPdfDictionaryObject(Desc);

  LoadCIDSystemInfo(D.Get('CIDSystemInfo'));
  if Assigned(D.Get('DW')) then FDefaultWidth := D.Get('DW').AsNumber;
  if Assigned(D.Get('W')) then LoadCIDWidths(D.Get('W'));
  if Assigned(D.Get('FontDescriptor')) then LoadFontDescriptor(D.Get('FontDescriptor'));

  // Vertical metrics. W2 is parsed enough to mark vertical mode and capture DW2.
  if Assigned(D.Get('W2')) then FVertical := True;
  if D.Get('DW2') is TPdfArrayObject then
    if TPdfArrayObject(D.Get('DW2')).Items.Count >= 2 then
      FDefaultVerticalWidth := TPdfObject(TPdfArrayObject(D.Get('DW2')).Items[1]).AsNumber;
end;

procedure TPdfFont.LoadFromDictionary(FontDict: TPdfDictionaryObject; ResolveProc: Pointer);
var
  FirstChar: Integer;
  EncObj: TPdfObject;
begin
  if not Assigned(FontDict) then Exit;

  BaseFont := FontDict.GetName('BaseFont');
  Subtype := FontDict.GetName('Subtype');

  // The current object model stores already-resolved dictionaries in most call
  // sites. Widths, FontDescriptor and DescendantFonts are usually indirect
  // references that the caller resolves separately via LoadWidths/LoadDescendant.
  EncObj := FontDict.Get('Encoding');
  LoadEncoding(EncObj);
  if IsVerticalCMapName(EncodingName) then FVertical := True;

  FirstChar := Trunc(FontDict.GetNumber('FirstChar', 0));
  LoadWidths(FontDict.Get('Widths'), FirstChar);

  if Assigned(FontDict.Get('FontDescriptor')) then
    LoadFontDescriptor(FontDict.Get('FontDescriptor'));

  if IsType0Font(Subtype) then
  begin
    LoadDescendantFont(FontDict.Get('DescendantFonts'));
    if FontDict.Get('Encoding') <> nil then
    begin
      EncodingName := ObjName(FontDict.Get('Encoding'));
      if IsVerticalCMapName(EncodingName) then FVertical := True;
    end;
  end;
end;

procedure TPdfFont.SetToUnicode(CMap: TPdfCMap);
begin
  FCMap.Free;
  FCMap := CMap;
end;

function TPdfFont.GlyphNameForCode(Code: Integer): string;
begin
  Result := FDifferences.Values[IntToStr(Code)];
  if Result = '' then
    Result := FEncoding.Values[IntToStr(Code)];
end;

function TPdfFont.GlyphNameToUnicode(const GlyphName: string): UnicodeString;
var
  N: string;
  V: Integer;
begin
  N := GlyphName;
  if N = '' then Exit('');

  // Adobe glyph-list conventions used in PDFs.
  if Pos('uni', N) = 1 then
  begin
    V := StrToIntDef('$' + Copy(N, 4, 4), -1);
    if V >= 0 then Exit(WideChar(V));
  end;
  if Pos('u', N) = 1 then
  begin
    V := StrToIntDef('$' + Copy(N, 2, 6), -1);
    if V >= 0 then Exit(WideChar(V));
  end;

  if Length(N) = 1 then Exit(UnicodeString(N));
  if N = 'space' then Exit(' ');
  if N = 'hyphen' then Exit('-');
  if N = 'minus' then Exit('-');
  if N = 'period' then Exit('.');
  if N = 'comma' then Exit(',');
  if N = 'colon' then Exit(':');
  if N = 'semicolon' then Exit(';');
  if N = 'slash' then Exit('/');
  if N = 'backslash' then Exit('\');
  if N = 'parenleft' then Exit('(');
  if N = 'parenright' then Exit(')');
  if N = 'bracketleft' then Exit('[');
  if N = 'bracketright' then Exit(']');
  if N = 'braceleft' then Exit('{');
  if N = 'braceright' then Exit('}');
  if N = 'quotedbl' then Exit('"');
  if N = 'quotesingle' then Exit('''');
  if N = 'quoteleft' then Exit(WideChar($2018));
  if N = 'quoteright' then Exit(WideChar($2019));
  if N = 'quotedblleft' then Exit(WideChar($201C));
  if N = 'quotedblright' then Exit(WideChar($201D));
  if N = 'endash' then Exit(WideChar($2013));
  if N = 'emdash' then Exit(WideChar($2014));
  if N = 'ellipsis' then Exit(WideChar($2026));
  if N = 'bullet' then Exit(WideChar($2022));
  if N = 'Euro' then Exit(WideChar($20AC));
  if N = 'trademark' then Exit(WideChar($2122));
  if N = 'copyright' then Exit(WideChar($00A9));
  if N = 'registered' then Exit(WideChar($00AE));

  if N = 'Agrave' then Exit(WideChar($00C0));
  if N = 'Aacute' then Exit(WideChar($00C1));
  if N = 'Acircumflex' then Exit(WideChar($00C2));
  if N = 'Atilde' then Exit(WideChar($00C3));
  if N = 'Adieresis' then Exit(WideChar($00C4));
  if N = 'Aring' then Exit(WideChar($00C5));
  if N = 'AE' then Exit(WideChar($00C6));
  if N = 'Ccedilla' then Exit(WideChar($00C7));
  if N = 'Egrave' then Exit(WideChar($00C8));
  if N = 'Eacute' then Exit(WideChar($00C9));
  if N = 'Ecircumflex' then Exit(WideChar($00CA));
  if N = 'Edieresis' then Exit(WideChar($00CB));
  if N = 'Igrave' then Exit(WideChar($00CC));
  if N = 'Iacute' then Exit(WideChar($00CD));
  if N = 'Icircumflex' then Exit(WideChar($00CE));
  if N = 'Idieresis' then Exit(WideChar($00CF));
  if N = 'Eth' then Exit(WideChar($00D0));
  if N = 'Ntilde' then Exit(WideChar($00D1));
  if N = 'Ograve' then Exit(WideChar($00D2));
  if N = 'Oacute' then Exit(WideChar($00D3));
  if N = 'Ocircumflex' then Exit(WideChar($00D4));
  if N = 'Otilde' then Exit(WideChar($00D5));
  if N = 'Odieresis' then Exit(WideChar($00D6));
  if N = 'Oslash' then Exit(WideChar($00D8));
  if N = 'Ugrave' then Exit(WideChar($00D9));
  if N = 'Uacute' then Exit(WideChar($00DA));
  if N = 'Ucircumflex' then Exit(WideChar($00DB));
  if N = 'Udieresis' then Exit(WideChar($00DC));
  if N = 'Yacute' then Exit(WideChar($00DD));
  if N = 'Thorn' then Exit(WideChar($00DE));
  if N = 'germandbls' then Exit(WideChar($00DF));
  if N = 'agrave' then Exit(WideChar($00E0));
  if N = 'aacute' then Exit(WideChar($00E1));
  if N = 'acircumflex' then Exit(WideChar($00E2));
  if N = 'atilde' then Exit(WideChar($00E3));
  if N = 'adieresis' then Exit(WideChar($00E4));
  if N = 'aring' then Exit(WideChar($00E5));
  if N = 'ae' then Exit(WideChar($00E6));
  if N = 'ccedilla' then Exit(WideChar($00E7));
  if N = 'egrave' then Exit(WideChar($00E8));
  if N = 'eacute' then Exit(WideChar($00E9));
  if N = 'ecircumflex' then Exit(WideChar($00EA));
  if N = 'edieresis' then Exit(WideChar($00EB));
  if N = 'igrave' then Exit(WideChar($00EC));
  if N = 'iacute' then Exit(WideChar($00ED));
  if N = 'icircumflex' then Exit(WideChar($00EE));
  if N = 'idieresis' then Exit(WideChar($00EF));
  if N = 'eth' then Exit(WideChar($00F0));
  if N = 'ntilde' then Exit(WideChar($00F1));
  if N = 'ograve' then Exit(WideChar($00F2));
  if N = 'oacute' then Exit(WideChar($00F3));
  if N = 'ocircumflex' then Exit(WideChar($00F4));
  if N = 'otilde' then Exit(WideChar($00F5));
  if N = 'odieresis' then Exit(WideChar($00F6));
  if N = 'oslash' then Exit(WideChar($00F8));
  if N = 'ugrave' then Exit(WideChar($00F9));
  if N = 'uacute' then Exit(WideChar($00FA));
  if N = 'ucircumflex' then Exit(WideChar($00FB));
  if N = 'udieresis' then Exit(WideChar($00FC));
  if N = 'yacute' then Exit(WideChar($00FD));
  if N = 'thorn' then Exit(WideChar($00FE));
  if N = 'ydieresis' then Exit(WideChar($00FF));
  if N = 'Scaron' then Exit(WideChar($0160));
  if N = 'scaron' then Exit(WideChar($0161));
  if N = 'OE' then Exit(WideChar($0152));
  if N = 'oe' then Exit(WideChar($0153));
  if N = 'Zcaron' then Exit(WideChar($017D));
  if N = 'zcaron' then Exit(WideChar($017E));
  if N = 'Ydieresis' then Exit(WideChar($0178));

  // Unknown glyph names are deliberately not guessed.
  Result := '';
end;

function TPdfFont.DecodeSimpleByte(B: Byte): UnicodeString;
var
  G: string;
begin
  G := GlyphNameForCode(B);
  Result := GlyphNameToUnicode(G);
  if Result = '' then
    Result := WideChar(B);
end;

function TPdfFont.DecodeCIDString(const S: AnsiString): UnicodeString;
var
  I, CID: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if I < Length(S) then
    begin
      CID := (Byte(S[I]) shl 8) or Byte(S[I + 1]);
      // Without ToUnicode, a CID is not a Unicode code point. Keep a stable
      // private-use placeholder so extraction remains lossless-ish to callers.
      Result := Result + WideChar($E000 + (CID mod $1900));
      Inc(I, 2);
    end
    else
    begin
      Result := Result + WideChar(Byte(S[I]));
      Inc(I);
    end;
  end;
end;

function TPdfFont.DecodeString(const S: AnsiString): UnicodeString;
var
  I: Integer;
begin
  if Assigned(FCMap) then Exit(FCMap.DecodeBytes(S));

  if IsType0Font(Subtype) then
    Exit(DecodeCIDString(S));

  Result := '';
  for I := 1 to Length(S) do
    Result := Result + DecodeSimpleByte(Byte(S[I]));
end;

// Standard Helvetica glyph widths (codes 32..126).
// Used as fallback for Arial / Helvetica Type1 fonts that carry no /Widths array.
// Source: Adobe Helvetica AFM.
const
  HelveticaWidths: array[32..126] of Integer = (
    // 32 spc..47 /
    278, 278, 355, 556, 556, 889, 667, 222, 333, 333, 389, 584, 278, 333, 278, 278,
    // 48 0..63 ?
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 278, 278, 584, 584, 584, 556,
    // 64 @..79 P
    1015,667, 667, 722, 722, 667, 611, 778, 722, 278, 500, 667, 556, 833, 722, 778,
    // 80 P..95 _
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 278, 278, 278, 469, 556,
    // 96 `..111 o
    222, 556, 556, 500, 556, 556, 278, 556, 556, 222, 222, 500, 222, 833, 556, 556,
    // 112 p..126 ~
    556, 556, 333, 500, 278, 556, 500, 722, 500, 500, 500, 334, 260, 334, 584
  );

// Times-Roman glyph widths (codes 32..126).
const
  TimesRomanWidths: array[32..126] of Integer = (
    // 32 spc..47 /
    250, 333, 408, 500, 500, 833, 778, 333, 333, 333, 500, 564, 250, 333, 250, 278,
    // 48 0..63 ?
    500, 500, 500, 500, 500, 500, 500, 500, 500, 500, 278, 278, 564, 564, 564, 444,
    // 64 @..79 P
    921, 722, 667, 667, 722, 611, 556, 722, 722, 333, 389, 722, 611, 889, 722, 722,
    // 80 P..95 _
    556, 722, 667, 556, 611, 722, 722, 944, 722, 722, 611, 333, 278, 333, 469, 500,
    // 96 `..111 o
    333, 444, 500, 444, 500, 444, 333, 500, 500, 278, 278, 500, 278, 778, 500, 500,
    // 112 p..126 ~
    500, 500, 333, 389, 278, 500, 500, 722, 500, 500, 444, 480, 200, 480, 541
  );

function StandardType1Width(const BF: string; Code: Integer): Double;
var
  Upper: string;
begin
  if (Code < 32) or (Code > 126) then
  begin
    Result := 556;  // reasonable default for out-of-range codes
    Exit;
  end;
  Upper := UpperCase(BF);
  if (Pos('ARIAL', Upper) > 0) or (Pos('HELVETICA', Upper) > 0) then
    Result := HelveticaWidths[Code]
  else if (Pos('TIMES', Upper) > 0) then
    Result := TimesRomanWidths[Code]
  else if (Pos('COURIER', Upper) > 0) then
    Result := 600  // Courier is monospace, all glyphs 600 em units
  else
    Result := HelveticaWidths[Code];  // conservative: use Helvetica as generic proportional fallback
end;

function TPdfFont.WidthOfCode(Code: Integer): Double;
begin
  if IsType0Font(Subtype) then
    Result := GetWidthFrom(FCIDWidths, Code, FDefaultWidth)
  else
  begin
    // When an explicit Widths array was loaded, use it (with FDefaultWidth for out-of-range codes).
    if Length(FWidths) > 0 then
      Result := GetWidthFrom(FWidths, Code, FDefaultWidth)
    else
      // No Widths entry: fall back to standard AFM metrics so that text-advance
      // calculations stay accurate for standard Type1 fonts (Arial, Helvetica, …).
      Result := StandardType1Width(BaseFont, Code);
  end;
end;

function TPdfFont.IsVerticalWriting: Boolean;
begin
  Result := FVertical;
end;

function TPdfFont.GlyphName(Code: Integer): string;
begin
  Result := GlyphNameForCode(Code);
end;

end.
