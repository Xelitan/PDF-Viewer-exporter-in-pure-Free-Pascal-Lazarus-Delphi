unit PdfCMap;
{$mode delphi}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
interface
uses SysUtils, Classes, Contnrs, StrUtils;

type
  TPdfCMapEntry = class
  public
    Code: AnsiString;
    UnicodeText: UnicodeString;
  end;

  TPdfCMap = class
  private
    FEntries: TObjectList;
  public
    constructor Create;
    destructor Destroy;
    override;
    procedure AddMapping(const Code: AnsiString; const UnicodeText: UnicodeString);
    function DecodeBytes(const Bytes: AnsiString): UnicodeString;
    procedure LoadFromText(const Text: AnsiString);
  end;

implementation

function HexToBytes(const H: AnsiString): AnsiString;
var I, V: Integer;
  S: string;
begin
  Result := '';
  I := 1;
  while I <= Length(H) - 1 do begin
    S := '$' + string(H[I]) + string(H[I+1]);
    V := StrToIntDef(S, 0);
    Result := Result + AnsiChar(V);
    Inc(I, 2);
  end;
end;

// Each Unicode BMP codepoint in a PDF CMap is encoded as 4 hex digits (big-endian UTF-16).
// Read 4 hex chars at a time to produce a single WideChar.
function HexToUnicode(const H: AnsiString): UnicodeString;
var I, V: Integer;
  S: string;
begin
  Result := '';
  I := 1;
  while I <= Length(H) - 3 do begin
    S := '$' + string(H[I]) + string(H[I+1]) + string(H[I+2]) + string(H[I+3]);
    V := StrToIntDef(S, 0);
    Result := Result + WideChar(V);
    Inc(I, 4);
  end;
  // Fallback: leftover 2-hex-char pair treated as 1-byte codepoint
  if I <= Length(H) - 1 then begin
    S := '$' + string(H[I]) + string(H[I+1]);
    V := StrToIntDef(S, 0);
    Result := Result + WideChar(V);
  end;
end;

function HexToInt(const H: AnsiString): Integer;
begin
  Result := StrToIntDef('$' + string(H), 0);
end;

// Build a ByteCount-byte big-endian key for integer Value.
function IntToCodeBytes(Value, ByteCount: Integer): AnsiString;
var I: Integer;
begin
  SetLength(Result, ByteCount);
  for I := ByteCount downto 1 do begin
    Result[I] := AnsiChar(Value and $FF);
    Value := Value shr 8;
  end;
end;

constructor TPdfCMap.Create;
begin
  inherited Create;
  FEntries := TObjectList.Create(True);
end;
destructor TPdfCMap.Destroy;
begin
  FEntries.Free;
  inherited Destroy;
end;

procedure TPdfCMap.AddMapping(const Code: AnsiString; const UnicodeText: UnicodeString);
var E: TPdfCMapEntry;
begin
  E := TPdfCMapEntry.Create;
  E.Code := Code;
  E.UnicodeText := UnicodeText;
  FEntries.Add(E);
end;

function TPdfCMap.DecodeBytes(const Bytes: AnsiString): UnicodeString;
var I, J, Best, BestLen: Integer;
  E: TPdfCMapEntry;
begin
  Result := '';
  I := 1;
  while I <= Length(Bytes) do begin
    Best := -1;
    BestLen := 0;
    for J := 0 to FEntries.Count - 1 do begin
      E := TPdfCMapEntry(FEntries[J]);
      if (Length(E.Code) > BestLen) and (Copy(Bytes, I, Length(E.Code)) = E.Code) then begin
        Best := J;
        BestLen := Length(E.Code);
      end;
    end;
    if Best >= 0 then begin
      E := TPdfCMapEntry(FEntries[Best]);
      Result := Result + E.UnicodeText;
      Inc(I, BestLen);
    end else begin
      Result := Result + WideChar(Byte(Bytes[I]));
      Inc(I);
    end;
  end;
end;

procedure TPdfCMap.LoadFromText(const Text: AnsiString);
var
  SL: TStringList;
  I, K: Integer;
  L, A, B, C, Rest: AnsiString;
  P1, P2, P3, P4, P5, P6, Q, QA, QB: Integer;
  InBfChar, InBfRange: Boolean;
  LowCode, HighCode, StartUni, ByteCount: Integer;
begin
  SL := TStringList.Create;
  try
    SL.Text := string(Text);
    InBfChar := False;
    InBfRange := False;
    for I := 0 to SL.Count - 1 do begin
      L := AnsiString(Trim(SL[I]));

      if Pos('beginbfchar', string(L)) > 0 then begin
        InBfChar := True;
        InBfRange := False;
        Continue;
      end;
      if Pos('endbfchar', string(L)) > 0 then begin
        InBfChar := False;
        Continue;
      end;
      if Pos('beginbfrange', string(L)) > 0 then begin
        InBfRange := True;
        InBfChar := False;
        Continue;
      end;
      if Pos('endbfrange', string(L)) > 0 then begin
        InBfRange := False;
        Continue;
      end;
      if (not InBfChar) and (not InBfRange) then Continue;

      P1 := Pos('<', string(L));
      if P1 = 0 then Continue;
      P2 := PosEx('>', string(L), P1 + 1);
      if P2 = 0 then Continue;
      A := Copy(L, P1 + 1, P2 - P1 - 1);

      P3 := PosEx('<', string(L), P2 + 1);
      if P3 = 0 then Continue;
      P4 := PosEx('>', string(L), P3 + 1);
      if P4 = 0 then Continue;
      B := Copy(L, P3 + 1, P4 - P3 - 1);

      if InBfChar then begin
        // <srcCode> <unicodeHex>
        AddMapping(HexToBytes(A), HexToUnicode(B));
      end else begin
        // bfrange has two destination forms:
        //   <lo> <hi> <startUni>        : lo->startUni, lo+1->startUni+1, ...
        //   <lo> <hi> [<u0> <u1> ...]   : lo->u0, lo+1->u1, ... (each its own value)
        // Misreading the array form as the incrementing one corrupts characters
        // (e.g. a period mapped to ';'), so handle the array explicitly.
        LowCode  := HexToInt(A);
        HighCode := HexToInt(B);
        ByteCount := Length(A) div 2;
        if ByteCount < 1 then ByteCount := 1;

        Rest := AnsiString(Trim(Copy(string(L), P4 + 1, Length(L))));
        if (Length(Rest) > 0) and (Rest[1] = '[') then
        begin
          // Array form: pair each consecutive <hex> with the next code.
          K := LowCode;
          Q := 1;
          while K <= HighCode do
          begin
            QA := PosEx('<', string(Rest), Q);
            if QA = 0 then Break;
            QB := PosEx('>', string(Rest), QA + 1);
            if QB = 0 then Break;
            C := Copy(Rest, QA + 1, QB - QA - 1);
            AddMapping(IntToCodeBytes(K, ByteCount), HexToUnicode(C));
            Inc(K);
            Q := QB + 1;
          end;
        end
        else
        begin
          // Incrementing form.
          P5 := PosEx('<', string(L), P4 + 1);
          if P5 = 0 then Continue;
          P6 := PosEx('>', string(L), P5 + 1);
          if P6 = 0 then Continue;
          C := Copy(L, P5 + 1, P6 - P5 - 1);
          StartUni := HexToInt(C);
          for K := LowCode to HighCode do
            AddMapping(IntToCodeBytes(K, ByteCount),
                       WideChar(StartUni + (K - LowCode)));
        end;
      end;
    end;
  finally
    SL.Free;
  end;
end;

end.
