unit PdfCcitt;
{$mode delphi}{$H+}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
//CCITT Group 3 / Group 4 fax decoder for PDF CCITTFaxDecode streams.
//
//
//Output is 8-bit grayscale, 1 byte per pixel, row-major: 0 = black, 255 = white
//(semantic fax colors; the caller applies /BlackIs1 + /Decode inversion if
//needed). This feeds the renderer's existing DrawRawDeviceGray path directly.
//
//  K < 0  : pure Group 4 (T.6) two-dimensional coding
//  K = 0  : pure one-dimensional MH (T.4); EOL codes are tolerated, not required
//  K > 0  : mixed G3 2D (T.4): every row is EOL + tag bit + (1D or 2D) row data

interface

uses
  Classes, SysUtils, PdfTypes;

// Decode CCITT bits. Columns > 0 required. Rows: expected row count (pad/stop);
//  pass 0 when unknown — decoding then runs until the data ends (EOFB/RTC or bit
//  exhaustion). Returns False only if nothing could be decoded.

function DecodeCCITTFax(const Data: TPdfBytes; K, Columns, Rows: Integer;
  ByteAlign: Boolean; out OutW, OutH: Integer; out Gray: TPdfBytes): Boolean;

implementation

type
  TCode = record
    Bits: Cardinal;
    Len: Byte;
    Run: Integer;   // -1 = EOL
  end;

  TBoolArray = array of Boolean;

var
  WTerm, BTerm, WMake, BMake: array of TCode;

procedure AddCode(var A: array of TCode; var N: Integer; Run: Integer; const S: string);
var
  i: Integer;
  v: Cardinal;
begin
  v := 0;
  for i := 1 to Length(S) do
    v := (v shl 1) or Ord(S[i] = '1');
  A[N].Bits := v;
  A[N].Len := Length(S);
  A[N].Run := Run;
  Inc(N);
end;

procedure InitTables;
var
  n: Integer;
begin
  SetLength(WTerm, 64); n := 0;
  AddCode(WTerm,n,0,'00110101'); AddCode(WTerm,n,1,'000111');
  AddCode(WTerm,n,2,'0111'); AddCode(WTerm,n,3,'1000');
  AddCode(WTerm,n,4,'1011'); AddCode(WTerm,n,5,'1100');
  AddCode(WTerm,n,6,'1110'); AddCode(WTerm,n,7,'1111');
  AddCode(WTerm,n,8,'10011'); AddCode(WTerm,n,9,'10100');
  AddCode(WTerm,n,10,'00111'); AddCode(WTerm,n,11,'01000');
  AddCode(WTerm,n,12,'001000'); AddCode(WTerm,n,13,'000011');
  AddCode(WTerm,n,14,'110100'); AddCode(WTerm,n,15,'110101');
  AddCode(WTerm,n,16,'101010'); AddCode(WTerm,n,17,'101011');
  AddCode(WTerm,n,18,'0100111'); AddCode(WTerm,n,19,'0001100');
  AddCode(WTerm,n,20,'0001000'); AddCode(WTerm,n,21,'0010111');
  AddCode(WTerm,n,22,'0000011'); AddCode(WTerm,n,23,'0000100');
  AddCode(WTerm,n,24,'0101000'); AddCode(WTerm,n,25,'0101011');
  AddCode(WTerm,n,26,'0010011'); AddCode(WTerm,n,27,'0100100');
  AddCode(WTerm,n,28,'0011000'); AddCode(WTerm,n,29,'00000010');
  AddCode(WTerm,n,30,'00000011'); AddCode(WTerm,n,31,'00011010');
  AddCode(WTerm,n,32,'00011011'); AddCode(WTerm,n,33,'00010010');
  AddCode(WTerm,n,34,'00010011'); AddCode(WTerm,n,35,'00010100');
  AddCode(WTerm,n,36,'00010101'); AddCode(WTerm,n,37,'00010110');
  AddCode(WTerm,n,38,'00010111'); AddCode(WTerm,n,39,'00101000');
  AddCode(WTerm,n,40,'00101001'); AddCode(WTerm,n,41,'00101010');
  AddCode(WTerm,n,42,'00101011'); AddCode(WTerm,n,43,'00101100');
  AddCode(WTerm,n,44,'00101101'); AddCode(WTerm,n,45,'00000100');
  AddCode(WTerm,n,46,'00000101'); AddCode(WTerm,n,47,'00001010');
  AddCode(WTerm,n,48,'00001011'); AddCode(WTerm,n,49,'01010010');
  AddCode(WTerm,n,50,'01010011'); AddCode(WTerm,n,51,'01010100');
  AddCode(WTerm,n,52,'01010101'); AddCode(WTerm,n,53,'00100100');
  AddCode(WTerm,n,54,'00100101'); AddCode(WTerm,n,55,'01011000');
  AddCode(WTerm,n,56,'01011001'); AddCode(WTerm,n,57,'01011010');
  AddCode(WTerm,n,58,'01011011'); AddCode(WTerm,n,59,'01001010');
  AddCode(WTerm,n,60,'01001011'); AddCode(WTerm,n,61,'00110010');
  AddCode(WTerm,n,62,'00110011'); AddCode(WTerm,n,63,'00110100');

  SetLength(BTerm, 64); n := 0;
  AddCode(BTerm,n,0,'0000110111'); AddCode(BTerm,n,1,'010');
  AddCode(BTerm,n,2,'11'); AddCode(BTerm,n,3,'10');
  AddCode(BTerm,n,4,'011'); AddCode(BTerm,n,5,'0011');
  AddCode(BTerm,n,6,'0010'); AddCode(BTerm,n,7,'00011');
  AddCode(BTerm,n,8,'000101'); AddCode(BTerm,n,9,'000100');
  AddCode(BTerm,n,10,'0000100'); AddCode(BTerm,n,11,'0000101');
  AddCode(BTerm,n,12,'0000111'); AddCode(BTerm,n,13,'00000100');
  AddCode(BTerm,n,14,'00000111'); AddCode(BTerm,n,15,'000011000');
  AddCode(BTerm,n,16,'0000010111'); AddCode(BTerm,n,17,'0000011000');
  AddCode(BTerm,n,18,'0000001000'); AddCode(BTerm,n,19,'00001100111');
  AddCode(BTerm,n,20,'00001101000'); AddCode(BTerm,n,21,'00001101100');
  AddCode(BTerm,n,22,'00000110111'); AddCode(BTerm,n,23,'00000101000');
  AddCode(BTerm,n,24,'00000010111'); AddCode(BTerm,n,25,'00000011000');
  AddCode(BTerm,n,26,'000011001010'); AddCode(BTerm,n,27,'000011001011');
  AddCode(BTerm,n,28,'000011001100'); AddCode(BTerm,n,29,'000011001101');
  AddCode(BTerm,n,30,'000001101000'); AddCode(BTerm,n,31,'000001101001');
  AddCode(BTerm,n,32,'000001101010'); AddCode(BTerm,n,33,'000001101011');
  AddCode(BTerm,n,34,'000011010010'); AddCode(BTerm,n,35,'000011010011');
  AddCode(BTerm,n,36,'000011010100'); AddCode(BTerm,n,37,'000011010101');
  AddCode(BTerm,n,38,'000011010110'); AddCode(BTerm,n,39,'000011010111');
  AddCode(BTerm,n,40,'000001101100'); AddCode(BTerm,n,41,'000001101101');
  AddCode(BTerm,n,42,'000011011010'); AddCode(BTerm,n,43,'000011011011');
  AddCode(BTerm,n,44,'000001010100'); AddCode(BTerm,n,45,'000001010101');
  AddCode(BTerm,n,46,'000001010110'); AddCode(BTerm,n,47,'000001010111');
  AddCode(BTerm,n,48,'000001100100'); AddCode(BTerm,n,49,'000001100101');
  AddCode(BTerm,n,50,'000001010010'); AddCode(BTerm,n,51,'000001010011');
  AddCode(BTerm,n,52,'000000100100'); AddCode(BTerm,n,53,'000000110111');
  AddCode(BTerm,n,54,'000000111000'); AddCode(BTerm,n,55,'000000100111');
  AddCode(BTerm,n,56,'000000101000'); AddCode(BTerm,n,57,'000001011000');
  AddCode(BTerm,n,58,'000001011001'); AddCode(BTerm,n,59,'000000101011');
  AddCode(BTerm,n,60,'000000101100'); AddCode(BTerm,n,61,'000001011010');
  AddCode(BTerm,n,62,'000001100110'); AddCode(BTerm,n,63,'000001100111');

  SetLength(WMake, 40); n := 0;
  AddCode(WMake,n,64,'11011'); AddCode(WMake,n,128,'10010');
  AddCode(WMake,n,192,'010111'); AddCode(WMake,n,256,'0110111');
  AddCode(WMake,n,320,'00110110'); AddCode(WMake,n,384,'00110111');
  AddCode(WMake,n,448,'01100100'); AddCode(WMake,n,512,'01100101');
  AddCode(WMake,n,576,'01101000'); AddCode(WMake,n,640,'01100111');
  AddCode(WMake,n,704,'011001100'); AddCode(WMake,n,768,'011001101');
  AddCode(WMake,n,832,'011010010'); AddCode(WMake,n,896,'011010011');
  AddCode(WMake,n,960,'011010100'); AddCode(WMake,n,1024,'011010101');
  AddCode(WMake,n,1088,'011010110'); AddCode(WMake,n,1152,'011010111');
  AddCode(WMake,n,1216,'011011000'); AddCode(WMake,n,1280,'011011001');
  AddCode(WMake,n,1344,'011011010'); AddCode(WMake,n,1408,'011011011');
  AddCode(WMake,n,1472,'010011000'); AddCode(WMake,n,1536,'010011001');
  AddCode(WMake,n,1600,'010011010'); AddCode(WMake,n,1664,'011000');
  AddCode(WMake,n,1728,'010011011');
  // Additional makeup codes shared by white and black runs.
  AddCode(WMake,n,1792,'00000001000'); AddCode(WMake,n,1856,'00000001100');
  AddCode(WMake,n,1920,'00000001101'); AddCode(WMake,n,1984,'000000010010');
  AddCode(WMake,n,2048,'000000010011'); AddCode(WMake,n,2112,'000000010100');
  AddCode(WMake,n,2176,'000000010101'); AddCode(WMake,n,2240,'000000010110');
  AddCode(WMake,n,2304,'000000010111'); AddCode(WMake,n,2368,'000000011100');
  AddCode(WMake,n,2432,'000000011101'); AddCode(WMake,n,2496,'000000011110');
  AddCode(WMake,n,2560,'000000011111');

  SetLength(BMake, 40); n := 0;
  AddCode(BMake,n,64,'0000001111'); AddCode(BMake,n,128,'000011001000');
  AddCode(BMake,n,192,'000011001001'); AddCode(BMake,n,256,'000001011011');
  AddCode(BMake,n,320,'000000110011'); AddCode(BMake,n,384,'000000110100');
  AddCode(BMake,n,448,'000000110101'); AddCode(BMake,n,512,'0000001101100');
  AddCode(BMake,n,576,'0000001101101'); AddCode(BMake,n,640,'0000001001010');
  AddCode(BMake,n,704,'0000001001011'); AddCode(BMake,n,768,'0000001001100');
  AddCode(BMake,n,832,'0000001001101'); AddCode(BMake,n,896,'0000001110010');
  AddCode(BMake,n,960,'0000001110011'); AddCode(BMake,n,1024,'0000001110100');
  AddCode(BMake,n,1088,'0000001110101'); AddCode(BMake,n,1152,'0000001110110');
  AddCode(BMake,n,1216,'0000001110111'); AddCode(BMake,n,1280,'0000001010010');
  AddCode(BMake,n,1344,'0000001010011'); AddCode(BMake,n,1408,'0000001010100');
  AddCode(BMake,n,1472,'0000001010101'); AddCode(BMake,n,1536,'0000001011010');
  AddCode(BMake,n,1600,'0000001011011'); AddCode(BMake,n,1664,'0000001100100');
  AddCode(BMake,n,1728,'0000001100101');
  // Additional makeup codes shared by white and black runs.
  AddCode(BMake,n,1792,'00000001000'); AddCode(BMake,n,1856,'00000001100');
  AddCode(BMake,n,1920,'00000001101'); AddCode(BMake,n,1984,'000000010010');
  AddCode(BMake,n,2048,'000000010011'); AddCode(BMake,n,2112,'000000010100');
  AddCode(BMake,n,2176,'000000010101'); AddCode(BMake,n,2240,'000000010110');
  AddCode(BMake,n,2304,'000000010111'); AddCode(BMake,n,2368,'000000011100');
  AddCode(BMake,n,2432,'000000011101'); AddCode(BMake,n,2496,'000000011110');
  AddCode(BMake,n,2560,'000000011111');
end;

type
  TBitReader = record
    Data: PByte;
    Size, Pos: Integer;
    Mask: Byte;
  end;

function ReadBit(var R: TBitReader): Integer;
var
  b: Byte;
begin
  if R.Pos >= R.Size then Exit(-1);
  b := R.Data[R.Pos];
  // PDF CCITTFaxDecode data is always MSB-first (TIFF FillOrder 1).

  if (b and R.Mask) <> 0 then Result := 1 else Result := 0;

  R.Mask := R.Mask shr 1;
  if R.Mask = 0 then
  begin
    R.Mask := $80;
    Inc(R.Pos);
  end;
end;

procedure AlignByte(var R: TBitReader);
begin
  if R.Mask <> $80 then
  begin
    R.Mask := $80;
    Inc(R.Pos);
  end;
end;

function AtEnd(const R: TBitReader): Boolean;
begin
  Result := R.Pos >= R.Size;
end;

function MatchCode(const A: array of TCode; Bits: Cardinal; Len: Integer;
  out Run: Integer): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(A) do
    if (A[i].Len = Len) and (A[i].Bits = Bits) then
    begin
      Run := A[i].Run;
      Exit(True);
    end;
  Result := False;
end;

function DecodeRun(var R: TBitReader; White: Boolean): Integer;
var
  bits: Cardinal;
  len, bit, run: Integer;
begin
  bits := 0;

  for len := 1 to 13 do
  begin
    bit := ReadBit(R);
    if bit < 0 then raise Exception.Create('Unexpected end of CCITT data');
    bits := (bits shl 1) or Cardinal(bit);

    if (len = 12) and (bits = 1) then Exit(-1); // EOL

    if White then
    begin
      if MatchCode(WTerm, bits, len, run) then Exit(run);
      if MatchCode(WMake, bits, len, run) then Exit(run);
    end
    else
    begin
      if MatchCode(BTerm, bits, len, run) then Exit(run);
      if MatchCode(BMake, bits, len, run) then Exit(run);
    end;
  end;

  raise Exception.Create('Bad CCITT Huffman code');
end;

function DecodeFullRun(var R: TBitReader; White: Boolean): Integer;
var
  part: Integer;
begin
  Result := 0;
  repeat
    part := DecodeRun(R, White);
    if part < 0 then
    begin
      if Result = 0 then
        Exit(part);
      Exit(Result);
    end;
    Inc(Result, part);
  until part < 64;
end;

function SkipToEOL(var R: TBitReader): Boolean;
var
  b, zeros: Integer;
begin
  // CCITT T.4 EOL is 000000000001.  Zero fill bits may precede the EOL, so we
  // scan for at least 11 zeros followed by a one.
  Result := False;
  zeros := 0;

  while True do
  begin
    b := ReadBit(R);
    if b < 0 then
      Exit(False);

    if b = 0 then
      Inc(zeros)
    else
    begin
      if zeros >= 11 then
        Exit(True);
      zeros := 0;
    end;
  end;
end;

type
  TG4Mode = (
    g4Pass,
    g4Horizontal,
    g4V0,
    g4VR1,
    g4VR2,
    g4VR3,
    g4VL1,
    g4VL2,
    g4VL3,
    g4EOF
  );

function DecodeG4Mode(var R: TBitReader): TG4Mode;
var
  bits: Cardinal;
  len, b: Integer;
begin
    bits := 0;

    for len := 1 to 13 do
    begin
      b := ReadBit(R);
      if b < 0 then
        Exit(g4EOF);

      bits := (bits shl 1) or Cardinal(b);

      case len of
        1:
          if bits = 1 then Exit(g4V0); // %1

        3:
          case bits of
            1: Exit(g4Horizontal); // %001
            3: Exit(g4VR1);        // %011
            2: Exit(g4VL1);        // %010
          end;

        4:
          if bits = 1 then Exit(g4Pass); // %0001

        6:
          case bits of
            3: Exit(g4VR2); // %000011
            2: Exit(g4VL2); // %000010
          end;

        7:
          case bits of
            3: Exit(g4VR3); // %0000011
            2: Exit(g4VL3); // %0000010
          end;

        12:
          if bits = 1 then // %000000000001
            Exit(g4EOF); // EOFB / EOL-like marker
      end;
    end;

    // Unknown/extension code — treat as end-of-data.
    Result := g4EOF;
end;

function NextChangingPixel(const Ref: array of Boolean; StartX: Integer;
  CurrentColor: Boolean; Width: Integer): Integer;
var
  prevColor: Boolean;
begin
  // Virtual white pixel exists at position -1 per T.6 spec.
  if StartX < 0 then
    prevColor := False
  else
    prevColor := Ref[StartX];

  Result := StartX + 1;
  while Result < Width do
  begin
    // A changing element of the opposite color: transition FROM CurrentColor TO not-CurrentColor.
    if (Ref[Result] <> CurrentColor) and (prevColor = CurrentColor) then
      Exit;
    prevColor := Ref[Result];
    Inc(Result);
  end;
  Result := Width;
end;

procedure FillRun(var Line: array of Boolean; X1, X2: Integer;
  Color: Boolean; Width: Integer);
var
  x: Integer;
begin
  if X1 < 0 then X1 := 0;
  if X2 > Width then X2 := Width;
  if X2 < X1 then Exit;

  for x := X1 to X2 - 1 do
    Line[x] := Color;
end;

function Decode1DLineToArray(var R: TBitReader; var Line: array of Boolean;
  Width: Integer): Boolean;
var
  x, i, run: Integer;
  white: Boolean;
begin
  for x := 0 to Width - 1 do
    Line[x] := False;

  x := 0;
  white := True;

  while x < Width do
  begin
    run := DecodeFullRun(R, white);
    if run < 0 then
    begin
      // EOL: tolerate as a row separator when seen before any pixels (PDF K=0
      // streams may carry optional EOLs); mid-row it ends the row early.
      if x = 0 then Continue;
      Break;
    end;

    for i := 0 to run - 1 do
    begin
      if x >= Width then Break;
      Line[x] := not white; // False=white, True=black
      Inc(x);
    end;

    white := not white;
  end;

  Result := True;
end;

function Decode2DLineToArray(var R: TBitReader; const RefLine: array of Boolean;
  var CurLine: array of Boolean; Width: Integer): Boolean;
var
  x, a0, a1, a2, b1, b2: Integer;
  color: Boolean; // False = white, True = black
  mode: TG4Mode;
  run1, run2: Integer;
begin
  for x := 0 to Width - 1 do
    CurLine[x] := False;

  a0 := 0;
  color := False;
  a1 := 0;

  while a0 < Width do
  begin
    b1 := NextChangingPixel(RefLine, a0, color, Width);

    if b1 < Width then
    begin
      b2 := b1 + 1;
      while (b2 < Width) and (RefLine[b2] <> color) do
        Inc(b2);
    end
    else
      b2 := Width;

    mode := DecodeG4Mode(R);

    case mode of
      g4EOF:
        begin
          Result := False;
          Exit;
        end;

      g4Pass:
        begin
          FillRun(CurLine, a0, b2, color, Width);
          a0 := b2;
        end;

      g4Horizontal:
        begin
          run1 := DecodeFullRun(R, not color);
          if run1 < 0 then
          begin
            Result := False;
            Exit;
          end;
          a1 := a0 + run1;

          run2 := DecodeFullRun(R, color);
          if run2 < 0 then
          begin
            Result := False;
            Exit;
          end;
          a2 := a1 + run2;

          FillRun(CurLine, a0, a1, color, Width);
          FillRun(CurLine, a1, a2, not color, Width);

          a0 := a2;
        end;

      g4V0:  a1 := b1;
      g4VR1: a1 := b1 + 1;
      g4VR2: a1 := b1 + 2;
      g4VR3: a1 := b1 + 3;
      g4VL1: a1 := b1 - 1;
      g4VL2: a1 := b1 - 2;
      g4VL3: a1 := b1 - 3;
    end;

    if mode in [g4V0, g4VR1, g4VR2, g4VR3, g4VL1, g4VL2, g4VL3] then
    begin
      if a1 < a0 then
        a1 := a0;
      FillRun(CurLine, a0, a1, color, Width);
      a0 := a1;
      color := not color;
    end;

    if a0 >= Width then
      Break;
  end;

  Result := True;
end;

procedure CopyLineToRef(const Src: array of Boolean; var Dst: TBoolArray;
  Width: Integer);
var
  i: Integer;
begin
  for i := 0 to Width - 1 do
    Dst[i] := Src[i];
end;

// ─=─=─=─=─=─=─=─=─=──=─=─=─ PDF entry point ─=─=─=─=─=─=─=─=─=─=─=─=─=─=─=─=

// Append one row of 0/255 gray bytes (Line=nil → all-white row). Standalone —
// NOT nested in DecodeCCITTFax — because growing an outer-local dynamic array
// via SetLength inside a nested procedure corrupts the stack frame in FPC
// (same workaround as the path arrays in PdfParser). Grows geometrically.
procedure EmitRowTo(var Gray: TPdfBytes; var RowsDone: Integer; Columns: Integer;
  const Line: TBoolArray);
var
  px, need: Integer;
begin
  need := (RowsDone + 1) * Columns;
  if Length(Gray) < need then
  begin
    if Length(Gray) = 0 then
      SetLength(Gray, need * 16)            // room for 16 rows up front
    else if Length(Gray) * 2 >= need then
      SetLength(Gray, Length(Gray) * 2)
    else
      SetLength(Gray, need);
  end;
  if Line = nil then
    for px := 0 to Columns - 1 do
      Gray[RowsDone * Columns + px] := 255
  else
    for px := 0 to Columns - 1 do
      if Line[px] then
        Gray[RowsDone * Columns + px] := 0     // black
      else
        Gray[RowsDone * Columns + px] := 255;  // white
  Inc(RowsDone);
end;

function DecodeCCITTFax(const Data: TPdfBytes; K, Columns, Rows: Integer;
  ByteAlign: Boolean; out OutW, OutH: Integer; out Gray: TPdfBytes): Boolean;
const
  MAX_ROWS = 32767;
var
  R: TBitReader;
  RefLine, CurLine: TBoolArray;
  RowsDone, Want, tagBit: Integer;
  ok: Boolean;
begin
  Result := False;
  OutW := Columns;
  OutH := 0;
  SetLength(Gray, 0);
  if (Columns <= 0) or (Length(Data) = 0) then Exit;
  if Length(WTerm) = 0 then InitTables;

  R.Data := @Data[0];
  R.Size := Length(Data);
  R.Pos := 0;
  R.Mask := $80;

  SetLength(RefLine, Columns);   // zero-initialised = all-white reference line
  SetLength(CurLine, Columns);

  if Rows > 0 then Want := Rows else Want := MAX_ROWS;
  if Want > MAX_ROWS then Want := MAX_ROWS;
  RowsDone := 0;

  try
    while RowsDone < Want do
    begin
      if AtEnd(R) then Break;

      if K < 0 then
      begin
        // ─= Group 4 (T.6): plain 2D lines, EOFB terminates ─=─=─=─=─=─=─=
        if ByteAlign then AlignByte(R);
        if not Decode2DLineToArray(R, RefLine, CurLine, Columns) then Break;
        EmitRowTo(Gray, RowsDone, Columns, CurLine);
        CopyLineToRef(CurLine, RefLine, Columns);
      end
      else if K = 0 then
      begin
        // ─= Pure 1D MH: rows of run codes; EOLs optional ─=─=─=─=─=─=─=─=
        if ByteAlign then AlignByte(R);
        if not Decode1DLineToArray(R, CurLine, Columns) then Break;
        EmitRowTo(Gray, RowsDone, Columns, CurLine);
      end
      else
      begin
        // ─= Mixed G3 2D: every row is EOL + tag bit (1=1D, 0=2D) ─=─=─=─=
        if not SkipToEOL(R) then Break;
        tagBit := ReadBit(R);
        if tagBit < 0 then Break;

        if tagBit = 1 then
          ok := Decode1DLineToArray(R, CurLine, Columns)
        else
          ok := Decode2DLineToArray(R, RefLine, CurLine, Columns);

        if not ok then Break;
        EmitRowTo(Gray, RowsDone, Columns, CurLine);
        CopyLineToRef(CurLine, RefLine, Columns);
      end;
    end;
  except
    // Truncated/corrupt tail — keep whatever rows decoded successfully.
  end;

  if RowsDone = 0 then Exit;

  // When the caller knows the row count, pad any missing rows with white so the
  // buffer is exactly Rows*Columns (renderer requires Length >= W*H).
  if Rows > 0 then
    while RowsDone < Rows do
      EmitRowTo(Gray, RowsDone, Columns, nil);

  OutH := RowsDone;
  SetLength(Gray, RowsDone * Columns);
  Result := True;
end;

end.
