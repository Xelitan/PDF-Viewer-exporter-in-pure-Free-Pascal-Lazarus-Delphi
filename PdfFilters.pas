unit PdfFilters;
{$mode delphi}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
interface

uses
  SysUtils, Classes, PdfTypes, zbase, zinflate;

type
  TPdfFilterEngine = class
  public
    class function ApplyFilter(const FilterName: string; const Input: TPdfBytes): TPdfBytes;
    static;
    class function ASCIIHexDecode(const Input: TPdfBytes): TPdfBytes;
    static;
    class function ASCII85Decode(const Input: TPdfBytes): TPdfBytes;
    static;
    class function LZWDecode(const Input: TPdfBytes): TPdfBytes;
    static;
    class function FlateDecode(const Input: TPdfBytes): TPdfBytes;
    static;
    class function RunLengthDecode(const Input: TPdfBytes): TPdfBytes;
    static;
  end;

implementation

function IsPdfWhite(B: Byte): Boolean;
begin
  Result := B in [0, 9, 10, 12, 13, 32];
end;

function HexValue(B: Byte): Integer;
begin
  if (B >= Ord('0')) and (B <= Ord('9')) then
    Result := B - Ord('0')
  else if (B >= Ord('A')) and (B <= Ord('F')) then
    Result := B - Ord('A') + 10
  else if (B >= Ord('a')) and (B <= Ord('f')) then
    Result := B - Ord('a') + 10
  else
    Result := -1;
end;

procedure AppendByte(var Output: TPdfBytes; var Count: Integer; B: Byte);
begin
  if Count >= Length(Output) then
  begin
    if Length(Output) = 0 then
      SetLength(Output, 256)
    else
      SetLength(Output, Length(Output) * 2);
  end;

  Output[Count] := B;
  Inc(Count);
end;

procedure AppendBytes(var Output: TPdfBytes; var Count: Integer; const Data: TPdfBytes);
var
  I: Integer;
begin
  for I := 0 to High(Data) do
    AppendByte(Output, Count, Data[I]);
end;

function BytesWithByte(B: Byte): TPdfBytes;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := B;
end;

function BytesConcatByte(const A: TPdfBytes; B: Byte): TPdfBytes;
var
  L: Integer;
begin
  Result := nil;
  L := Length(A);
  SetLength(Result, L + 1);

  if L > 0 then
    Move(A[0], Result[0], L);

  Result[L] := B;
end;

function FirstByteOf(const A: TPdfBytes): Byte;
begin
  if Length(A) = 0 then
    Result := 0
  else
    Result := A[0];
end;

type
  TLZWBitReader = record
    Data: TPdfBytes;
    BitPos: Integer;
    function ReadCode(CodeSize: Integer; out Code: Integer): Boolean;
  end;

function TLZWBitReader.ReadCode(CodeSize: Integer; out Code: Integer): Boolean;
var
  I, BytePos, BitInByte: Integer;
begin
  Result := False;
  Code := 0;

  if BitPos + CodeSize > Length(Data) * 8 then
    Exit;

  for I := 0 to CodeSize - 1 do
  begin
    BytePos := (BitPos + I) div 8;
    BitInByte := 7 - ((BitPos + I) mod 8);

    Code := (Code shl 1) or ((Data[BytePos] shr BitInByte) and 1);
  end;

  Inc(BitPos, CodeSize);
  Result := True;
end;

class function TPdfFilterEngine.ApplyFilter(const FilterName: string; const Input: TPdfBytes): TPdfBytes;
begin
  if FilterName = 'ASCIIHexDecode' then
    Result := ASCIIHexDecode(Input)
  else if FilterName = 'AHx' then
    Result := ASCIIHexDecode(Input)
  else if FilterName = 'ASCII85Decode' then
    Result := ASCII85Decode(Input)
  else if FilterName = 'A85' then
    Result := ASCII85Decode(Input)
  else if FilterName = 'LZWDecode' then
    Result := LZWDecode(Input)
  else if FilterName = 'LZW' then
    Result := LZWDecode(Input)
  else if FilterName = 'FlateDecode' then
    Result := FlateDecode(Input)
  else if FilterName = 'Fl' then
    Result := FlateDecode(Input)
  else if FilterName = 'RunLengthDecode' then
    Result := RunLengthDecode(Input)
  else if FilterName = 'RL' then
    Result := RunLengthDecode(Input)
  else
    Result := Input;
end;

class function TPdfFilterEngine.ASCIIHexDecode(const Input: TPdfBytes): TPdfBytes;
var
  I, H, N, Count: Integer;
  HaveHigh: Boolean;
  HighNibble: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Input) div 2 + 2);
  Count := 0;
  HaveHigh := False;
  HighNibble := 0;

  for I := 0 to High(Input) do
  begin
    if Input[I] = Ord('>') then
      Break;

    if IsPdfWhite(Input[I]) then
      Continue;

    N := HexValue(Input[I]);

    if N < 0 then
      Continue;

    if not HaveHigh then
    begin
      HighNibble := N;
      HaveHigh := True;
    end
    else
    begin
      H := (HighNibble shl 4) or N;
      AppendByte(Result, Count, Byte(H));
      HaveHigh := False;
    end;
  end;

  if HaveHigh then
    AppendByte(Result, Count, Byte(HighNibble shl 4));

  SetLength(Result, Count);
end;

class function TPdfFilterEngine.ASCII85Decode(const Input: TPdfBytes): TPdfBytes;
var
  I, J, Count, GroupCount: Integer;
  Ch: Byte;
  Group: array[0..4] of Integer;
  Value: QWord;
  Temp: array[0..3] of Byte;
begin
  Result := nil;
  SetLength(Result, Length(Input));
  Count := 0;
  GroupCount := 0;
  I := 0;

  while I < Length(Input) do
  begin
    Ch := Input[I];
    Inc(I);

    if IsPdfWhite(Ch) then
      Continue;

    if Ch = Ord('~') then
      Break;

    if (Ch = Ord('z')) and (GroupCount = 0) then
    begin
      AppendByte(Result, Count, 0);
      AppendByte(Result, Count, 0);
      AppendByte(Result, Count, 0);
      AppendByte(Result, Count, 0);
      Continue;
    end;

    if (Ch < Ord('!')) or (Ch > Ord('u')) then
      Continue;

    Group[GroupCount] := Ch - Ord('!');
    Inc(GroupCount);

    if GroupCount = 5 then
    begin
      Value := 0;

      for J := 0 to 4 do
        Value := Value * 85 + QWord(Group[J]);

      Temp[0] := Byte((Value shr 24) and $FF);
      Temp[1] := Byte((Value shr 16) and $FF);
      Temp[2] := Byte((Value shr 8) and $FF);
      Temp[3] := Byte(Value and $FF);

      for J := 0 to 3 do
        AppendByte(Result, Count, Temp[J]);

      GroupCount := 0;
    end;
  end;

  if GroupCount > 0 then
  begin
    for J := GroupCount to 4 do
      Group[J] := 84;

    Value := 0;

    for J := 0 to 4 do
      Value := Value * 85 + QWord(Group[J]);

    Temp[0] := Byte((Value shr 24) and $FF);
    Temp[1] := Byte((Value shr 16) and $FF);
    Temp[2] := Byte((Value shr 8) and $FF);
    Temp[3] := Byte(Value and $FF);

    for J := 0 to GroupCount - 2 do
      AppendByte(Result, Count, Temp[J]);
  end;

  SetLength(Result, Count);
end;

class function TPdfFilterEngine.LZWDecode(const Input: TPdfBytes): TPdfBytes;
const
  CLEAR_CODE = 256;
  EOD_CODE = 257;
  FIRST_CODE = 258;
  MAX_CODES = 4096;
var
  Reader: TLZWBitReader;
  Table: array[0..MAX_CODES - 1] of TPdfBytes;
  CodeSize: Integer;
  NextCode: Integer;
  PrevCode: Integer;
  Code: Integer;
  Entry: TPdfBytes;
  Count: Integer;

  procedure ResetTable;
  var
    I: Integer;
  begin
    for I := 0 to MAX_CODES - 1 do
      SetLength(Table[I], 0);

    for I := 0 to 255 do
      Table[I] := BytesWithByte(Byte(I));

    CodeSize := 9;
    NextCode := FIRST_CODE;
    PrevCode := -1;
  end;

  procedure AddTableEntry(const Prefix: TPdfBytes; B: Byte);
  begin
    if NextCode >= MAX_CODES then
      Exit;

    Table[NextCode] := BytesConcatByte(Prefix, B);
    Inc(NextCode);

    if (CodeSize < 12) and (NextCode = ((1 shl CodeSize) - 1)) then
      Inc(CodeSize);
  end;

begin
  Result := nil;
  SetLength(Result, Length(Input) * 4 + 1024);
  Count := 0;

  Reader.Data := Input;
  Reader.BitPos := 0;

  ResetTable;

  while Reader.ReadCode(CodeSize, Code) do
  begin
    if Code = CLEAR_CODE then
    begin
      ResetTable;
      Continue;
    end;

    if Code = EOD_CODE then
      Break;

    if (Code >= 0) and (Code < NextCode) and (Length(Table[Code]) > 0) then
      Entry := Table[Code]
    else if (Code = NextCode) and (PrevCode >= 0) then
      Entry := BytesConcatByte(Table[PrevCode], FirstByteOf(Table[PrevCode]))
    else
      Break;

    AppendBytes(Result, Count, Entry);

    if PrevCode >= 0 then
      AddTableEntry(Table[PrevCode], FirstByteOf(Entry));

    PrevCode := Code;
  end;

  SetLength(Result, Count);
end;

class function TPdfFilterEngine.FlateDecode(const Input: TPdfBytes): TPdfBytes;
const
  BufSize = 65536;
var
  Strm: z_stream;
  OutStream: TMemoryStream;
  OutBuf: TPdfBytes;
  Ret, Have: Integer;
begin
  // Inflate via the raw paszlib API with RETURN-CODE checking rather than
  // TDecompressionStream. The stream wrapper raises EDecompressionError on
  // zlib's Z_BUF_ERROR/Z_DATA_ERROR — which is common and benign here because
  // many PDFs pad /Length with trailing bytes after the zlib data — and that
  // exception both trips the debugger and is fragile. Here a non-Z_OK return
  // simply ends the loop, keeping whatever was already inflated.
  Result := nil;
  if Length(Input) = 0 then Exit;

  FillChar(Strm, SizeOf(Strm), 0);
  if inflateInit(Strm) <> Z_OK then Exit;

  OutStream := TMemoryStream.Create;
  SetLength(OutBuf, BufSize);
  try
    Strm.next_in := @Input[0];
    Strm.avail_in := Length(Input);
    repeat
      Strm.next_out := @OutBuf[0];
      Strm.avail_out := BufSize;
      Ret := inflate(Strm, Z_NO_FLUSH);
      Have := BufSize - Integer(Strm.avail_out);
      if Have > 0 then OutStream.WriteBuffer(OutBuf[0], Have);
      // Z_OK = made progress, keep going. Z_STREAM_END = done. Any error
      // (Z_BUF_ERROR when input runs out, Z_DATA_ERROR on corruption) ends the
      // loop with the partial output retained.
    until Ret <> Z_OK;
    inflateEnd(Strm);

    SetLength(Result, OutStream.Size);
    if OutStream.Size > 0 then
    begin
      OutStream.Position := 0;
      OutStream.ReadBuffer(Result[0], OutStream.Size);
    end;
  finally
    OutStream.Free;
  end;
end;

class function TPdfFilterEngine.RunLengthDecode(const Input: TPdfBytes): TPdfBytes;
var
  I, J, Count, N, RepeatCount: Integer;
  B: Byte;
begin
  Result := nil;
  SetLength(Result, Length(Input) * 2 + 256);
  Count := 0;
  I := 0;

  while I < Length(Input) do
  begin
    N := Input[I];
    Inc(I);

    if N = 128 then
      Break;

    if N <= 127 then
    begin
      for J := 0 to N do
      begin
        if I >= Length(Input) then
          Break;

        AppendByte(Result, Count, Input[I]);
        Inc(I);
      end;
    end
    else
    begin
      if I >= Length(Input) then
        Break;

      B := Input[I];
      Inc(I);

      RepeatCount := 257 - N;

      for J := 1 to RepeatCount do
        AppendByte(Result, Count, B);
    end;
  end;

  SetLength(Result, Count);
end;

end.
