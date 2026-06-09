unit PdfCFF;

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
//Wrap a bare CFF (Type1C / FontFile3) font program into a minimal OpenType
//(OTF, 'OTTO') SFNT container that Windows GDI's AddFontMemResourceEx accepts.

//PDFs frequently embed Type1/Futura/etc. display fonts as CFF, which GDI cannot
//load directly. We parse just enough of the CFF (CharStrings count = numGlyphs,
//the charset GID->glyph-name, FontMatrix for unitsPerEm, and per-glyph advance
//widths from the Type2 charstrings) and emit the required SFNT tables
//(CFF /OS2/cmap/head/hhea/hmtx/maxp/name/post). The cmap maps Unicode -> GID via
//the glyph names so the existing Unicode TextOut path renders the embedded
//outlines. Returns nil on any parse failure (caller falls back to a substitute).

{$mode delphi}

interface

uses SysUtils, Classes, PdfTypes;

function WrapCFFToOTF(const CFF: TPdfBytes; const FamilyName: AnsiString): TPdfBytes;
// Add a minimal cmap and/or post table to a TrueType/OpenType font that lacks
// them (common in PDF-embedded subsets) so Windows can open/install it.
function EnsureFontTables(const Font: TPdfBytes): TPdfBytes;

implementation

var
  StdUni: array[0..390] of Word;  // standard-string SID -> Unicode

// =- big-endian readers =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
function RdU8(const D: TPdfBytes; P: Integer): Integer;
begin
  if (P >= 0) and (P < Length(D)) then Result := D[P] else Result := 0;
end;
function RdU16(const D: TPdfBytes; P: Integer): Integer;
begin
  Result := (RdU8(D,P) shl 8) or RdU8(D,P+1);
end;
function RdU24(const D: TPdfBytes; P: Integer): Integer;
begin
  Result := (RdU8(D,P) shl 16) or (RdU8(D,P+1) shl 8) or RdU8(D,P+2);
end;
function RdU32(const D: TPdfBytes; P: Integer): Int64;
begin
  Result := (Int64(RdU8(D,P)) shl 24) or (RdU8(D,P+1) shl 16) or (RdU8(D,P+2) shl 8) or RdU8(D,P+3);
end;
function RdOff(const D: TPdfBytes; P, Sz: Integer): Integer;
begin
  case Sz of
    1: Result := RdU8(D,P);
    2: Result := RdU16(D,P);
    3: Result := RdU24(D,P);
  else Result := Integer(RdU32(D,P));
  end;
end;

// =- big-endian writers =-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-
procedure W8(S: TStream; V: Byte);
begin
  S.WriteBuffer(V, 1);
end;
procedure W16(S: TStream; V: Word);
var B: array[0..1] of Byte;
begin
  B[0]:=Hi(V);
  B[1]:=Lo(V);
  S.WriteBuffer(B,2);
end;
procedure W16i(S: TStream; V: Integer);
begin
  W16(S, Word(SmallInt(V)));
end;
procedure W32(S: TStream; V: LongWord);
var B: array[0..3] of Byte;
begin
  B[0]:=(V shr 24) and $FF;
  B[1]:=(V shr 16) and $FF;
  B[2]:=(V shr 8) and $FF;
  B[3]:=V and $FF;
  S.WriteBuffer(B,4);
end;
procedure WTag(S: TStream; const T: AnsiString);
var I: Integer;
begin
  for I:=1 to 4 do W8(S, Ord(T[I]));
end;

type
  TIndex = record
    Count, DataStart, EndPos: Integer;
    Off: array of Integer;
  end;
  TDictEntry = record
    Op: Integer;
    Vals: array of Double;
  end;
  TDict = array of TDictEntry;

function ReadIndex(const D: TPdfBytes; P: Integer): TIndex;
var i, offSize, base: Integer;
begin
  Result.Count := 0;
  Result.DataStart := P+2;
  Result.EndPos := P+2;
  SetLength(Result.Off,0);
  if P+2 > Length(D) then Exit;
  Result.Count := RdU16(D,P);
  if Result.Count = 0 then Exit;
  offSize := RdU8(D,P+2);
  if (offSize < 1) or (offSize > 4) then begin
    Result.Count := 0;
    Exit;
  end;
  base := P+3;
  SetLength(Result.Off, Result.Count+1);
  for i := 0 to Result.Count do Result.Off[i] := RdOff(D, base + i*offSize, offSize);
  Result.DataStart := base + (Result.Count+1)*offSize - 1;
  Result.EndPos := Result.DataStart + Result.Off[Result.Count];
end;

function IndexObj(const D: TPdfBytes; const Idx: TIndex; i: Integer): TPdfBytes;
var a, b, n: Integer;
begin
  Result := nil;
  if (i < 0) or (i >= Idx.Count) then Exit;
  a := Idx.DataStart + Idx.Off[i];
  b := Idx.DataStart + Idx.Off[i+1];
  n := b - a;
  if n <= 0 then Exit;
  SetLength(Result, n);
  if (a >= 0) and (a + n <= Length(D)) then Move(D[a], Result[0], n) else SetLength(Result,0);
end;

function ParseReal(const D: TPdfBytes; var P: Integer): Double;
var s: string;
  done: Boolean;
  nib, kk, code: Integer;
  r: Double;
begin
  s := '';
  done := False;
  while (P < Length(D)) and not done do
  begin
    Inc(P);
    if P >= Length(D) then Break;
    for kk := 0 to 1 do
    begin
      if kk=0 then nib := D[P] shr 4 else nib := D[P] and $F;
      case nib of
        0..9: s := s + Chr(Ord('0')+nib);
        $a: s := s + '.';
        $b: s := s + 'E';
        $c: s := s + 'E-';
        $e: s := s + '-';
        $f: begin
          done := True;
          Break;
        end;
      end;
    end;
  end;
  Inc(P);
  r := 0;
  if s <> '' then begin
    Val(s, r, code);
    if code <> 0 then r := 0;
  end;
  Result := r;
end;

function ParseDict(const D: TPdfBytes): TDict;
var P, N, b0, op, nOps: Integer;
  operands: array of Double;
begin
  SetLength(Result,0);
  SetLength(operands,0);
  nOps := 0;
  P := 0;
  N := Length(D);
  while P < N do
  begin
    b0 := D[P];
    if b0 >= 32 then
    begin
      SetLength(operands,nOps+1);
      if b0 <= 246 then begin
        operands[nOps]:=b0-139;
        Inc(P);
      end
      else if b0 <= 250 then begin
        operands[nOps]:=(b0-247)*256 + RdU8(D,P+1) + 108;
        Inc(P,2);
      end
      else if b0 <= 254 then begin
        operands[nOps]:=-(b0-251)*256 - RdU8(D,P+1) - 108;
        Inc(P,2);
      end
      else begin
        operands[nOps]:=0;
        Inc(P,5);
      end;  // 255 reserved in DICT
      Inc(nOps);
    end
    else if b0 = 28 then begin
      SetLength(operands,nOps+1);
      operands[nOps]:=SmallInt(RdU16(D,P+1));
      Inc(nOps);
      Inc(P,3);
    end
    else if b0 = 29 then begin
      SetLength(operands,nOps+1);
      operands[nOps]:=Integer(RdU32(D,P+1));
      Inc(nOps);
      Inc(P,5);
    end
    else if b0 = 30 then begin
      SetLength(operands,nOps+1);
      operands[nOps]:=ParseReal(D,P);
      Inc(nOps);
    end
    else
    begin
      op := b0;
      Inc(P);
      if b0 = 12 then begin
        op := 1200 + RdU8(D,P);
        Inc(P);
      end;
      SetLength(Result, Length(Result)+1);
      Result[High(Result)].Op := op;
      SetLength(Result[High(Result)].Vals, nOps);
      if nOps > 0 then Move(operands[0], Result[High(Result)].Vals[0], nOps*SizeOf(Double));
      SetLength(operands,0);
      nOps := 0;
    end;
  end;
end;

function DictGet(const Dt: TDict; Op, Idx: Integer; Def: Double): Double;
var i: Integer;
begin
  Result := Def;
  for i := 0 to High(Dt) do
    if Dt[i].Op = Op then
    begin
      if (Idx >= 0) and (Idx <= High(Dt[i].Vals)) then Result := Dt[i].Vals[Idx];
      Exit;
    end;
end;
function DictHas(const Dt: TDict; Op: Integer): Boolean;
var i: Integer;
begin
  Result := False;
  for i:=0 to High(Dt) do if Dt[i].Op=Op then Exit(True);
end;

function HexNib(c: AnsiChar): Integer;
begin
  if (c>='0') and (c<='9') then Result := Ord(c)-Ord('0')
  else if (c>='A') and (c<='F') then Result := Ord(c)-Ord('A')+10
  else if (c>='a') and (c<='f') then Result := Ord(c)-Ord('a')+10
  else Result := -1;
end;

function NameToUnicode(const nm: AnsiString): Integer;
var i, v, d: Integer;
begin
  Result := 0;
  if nm = '' then Exit;
  if (Length(nm) >= 7) and (Copy(nm,1,3)='uni') then
  begin
    v := 0;
    for i := 4 to 7 do begin
      d := HexNib(nm[i]);
      if d<0 then begin
        v:=0;
        Break;
      end;
      v := v*16+d;
    end;
    if v > 0 then Exit(v);
  end;
  if Length(nm) = 1 then Exit(Ord(nm[1]));
  if nm='aogonek' then Exit($0105);
  if nm='Aogonek' then Exit($0104);
  if nm='eogonek' then Exit($0119);
  if nm='Eogonek' then Exit($0118);
  if nm='lslash' then Exit($0142);
  if nm='Lslash' then Exit($0141);
  if nm='nacute' then Exit($0144);
  if nm='Nacute' then Exit($0143);
  if nm='sacute' then Exit($015B);
  if nm='Sacute' then Exit($015A);
  if nm='zacute' then Exit($017A);
  if nm='Zacute' then Exit($0179);
  if nm='zdotaccent' then Exit($017C);
  if nm='Zdotaccent' then Exit($017B);
  if nm='cacute' then Exit($0107);
  if nm='Cacute' then Exit($0106);
  if nm='oacute' then Exit($00F3);
  if nm='Oacute' then Exit($00D3);
  if nm='scaron' then Exit($0161);
  if nm='Scaron' then Exit($0160);
  if nm='zcaron' then Exit($017E);
  if nm='Zcaron' then Exit($017D);
  if nm='space' then Exit($20);
end;

function CharstringWidth(const cs: TPdfBytes; defW, nomW: Integer): Integer;
var P, N, b0, nStems: Integer;
  haveW: Boolean;
    st: array[0..63] of Double;
    sp: Integer;
    procedure Push(v: Double);
    begin
      if sp <= High(st) then begin
        st[sp]:=v;
        Inc(sp);
      end;
    end;
    procedure CheckStem;
    begin
      if not haveW then begin
        if (sp and 1)=1 then Result := nomW + Round(st[0]);
        haveW := True;
      end;
    end;
begin
  Result := defW;
  haveW := False;
  nStems := 0;
  sp := 0;
  P := 0;
  N := Length(cs);
  while P < N do
  begin
    b0 := cs[P];
    if b0 >= 32 then
    begin
      if b0 <= 246 then begin
        Push(b0-139);
        Inc(P);
      end
      else if b0 <= 250 then begin
        Push((b0-247)*256 + RdU8(cs,P+1) + 108);
        Inc(P,2);
      end
      else if b0 <= 254 then begin
        Push(-(b0-251)*256 - RdU8(cs,P+1) - 108);
        Inc(P,2);
      end
      else begin
        Push(Integer(RdU32(cs,P+1)) / 65536.0);
        Inc(P,5);
      end;
    end
    else if b0 = 28 then begin
      Push(SmallInt(RdU16(cs,P+1)));
      Inc(P,3);
    end
    else
    begin
      case b0 of
        1,3,18,23: begin
          CheckStem;
          nStems := nStems + (sp div 2);
          sp := 0;
          Inc(P);
        end;
        19,20:     begin
          CheckStem;
          nStems := nStems + (sp div 2);
          sp := 0;
          Inc(P);
          Inc(P, (nStems+7) div 8);
        end;
        21: begin
          if not haveW then begin
            if sp > 2 then Result := nomW + Round(st[0]);
            haveW := True;
          end;
          Exit;
        end;
        22, 4: begin
          if not haveW then begin
            if sp > 1 then Result := nomW + Round(st[0]);
            haveW := True;
          end;
          Exit;
        end;
        14: begin
          if not haveW then begin
            if (sp > 0) and (sp <> 4) then Result := nomW + Round(st[0]);
            haveW := True;
          end;
          Exit;
        end;
        12: begin
          Inc(P,2);
          sp := 0;
        end;
        10, 29: Exit;
      else begin
        sp := 0;
        Inc(P);
      end;
      end;
    end;
  end;
end;

function TableChecksum(const B: TBytes): LongWord;
var i: Integer;
  w: LongWord;
begin
  Result := 0;
  i := 0;
  while i + 3 < Length(B) do
  begin
    w := (LongWord(B[i]) shl 24) or (LongWord(B[i+1]) shl 16) or (LongWord(B[i+2]) shl 8) or LongWord(B[i+3]);
    Result := Result + w;
    i := i + 4;
  end;
end;

function StreamBytes(S: TMemoryStream): TBytes;
begin
  SetLength(Result, S.Size);
  if S.Size>0 then Move(S.Memory^, Result[0], S.Size);
end;

function Pad4(const B: TBytes): TBytes;
var n, oldLen: Integer;
begin
  Result := Copy(B, 0, Length(B));
  oldLen := Length(Result);
  n := (4 - (oldLen and 3)) and 3;
  if n > 0 then begin
    SetLength(Result, oldLen+n);
    FillChar(Result[oldLen], n, 0);
  end;
end;

procedure BuildName(S: TStream; const Fam, PS: AnsiString);
var ids: array[0..4] of Integer;
  strs: array[0..4] of AnsiString;
    i, j, storageOff, soff: Integer;
begin
  ids[0]:=1;
  strs[0]:=Fam;
  ids[1]:=2;
  strs[1]:='Regular';
  ids[2]:=3;
  strs[2]:=Fam;
  ids[3]:=4;
  strs[3]:=Fam;
  ids[4]:=6;
  strs[4]:=PS;
  W16(S,0);
  W16(S,5);
  storageOff := 6 + 5*12;
  W16(S, storageOff);
  soff := 0;
  for i := 0 to 4 do
  begin
    W16(S,3);
    W16(S,1);
    W16(S,$0409);
    W16(S,ids[i]);
    W16(S, Length(strs[i])*2);
    W16(S, soff);
    soff := soff + Length(strs[i])*2;
  end;
  for i := 0 to 4 do
    for j := 1 to Length(strs[i]) do begin
      W8(S,0);
      W8(S,Ord(strs[i][j]));
    end;
end;

function WrapCFFToOTF(const CFF: TPdfBytes; const FamilyName: AnsiString): TPdfBytes;
var
  hdrSize: Integer;
  nameIdx, topIdx, strIdx, csIdx: TIndex;
  topDict, privDict: TDict;
  csOff, charsetOff, privSz, privOff, numGlyphs, i, gid, sid: Integer;
  unitsPerEm, defW, nomW: Integer;
  fm0: Double;
  gidWidth: array of Integer;
  uniToGid: array of Integer;
  csObj: TPdfBytes;
  fmt, first, nLeft, g, t: Integer;
  segU: array of Integer;
  segCount, nSeg, j: Integer;
  cffT, os2T, cmapT, headT, hheaT, hmtxT, maxpT, nameT, postT, out_: TMemoryStream;
  tabB: array[0..8] of TBytes;
  tabTag: array[0..8] of AnsiString;
  numTables, searchRange, entrySel, rangeShift, off, k: Integer;
  asc, desc, winAsc, winDesc, maxAdv, avgW, minU, maxU: Integer;
  psName, nm: AnsiString;
  headOffInFont: Integer;
  fontB: TBytes;
  adj: LongWord;
  savedPos: Int64;
  so: TPdfBytes;
  m, uni: Integer;
begin
  Result := nil;
  if Length(CFF) < 4 then Exit;
  if RdU8(CFF,0) <> 1 then Exit;
  hdrSize := RdU8(CFF,2);
  if (hdrSize < 4) or (hdrSize > Length(CFF)) then Exit;

  nameIdx := ReadIndex(CFF, hdrSize);
  topIdx  := ReadIndex(CFF, nameIdx.EndPos);
  strIdx  := ReadIndex(CFF, topIdx.EndPos);
  if topIdx.Count < 1 then Exit;

  topDict := ParseDict(IndexObj(CFF, topIdx, 0));
  if DictHas(topDict, 1230) then Exit;  // ROS -> CIDFont
  csOff := Round(DictGet(topDict, 17, 0, 0));
  charsetOff := Round(DictGet(topDict, 15, 0, 0));
  if csOff <= 0 then Exit;

  fm0 := DictGet(topDict, 1207, 0, 0.001);
  if fm0 <= 0 then fm0 := 0.001;
  unitsPerEm := Round(1.0 / fm0);
  if (unitsPerEm < 16) or (unitsPerEm > 16384) then unitsPerEm := 1000;

  csIdx := ReadIndex(CFF, csOff);
  numGlyphs := csIdx.Count;
  if (numGlyphs < 1) or (numGlyphs > 65535) then Exit;

  defW := 0;
  nomW := 0;
  privSz := Round(DictGet(topDict, 18, 0, 0));
  privOff := Round(DictGet(topDict, 18, 1, 0));
  if (privSz > 0) and (privOff > 0) and (privOff+privSz <= Length(CFF)) then
  begin
    privDict := ParseDict(Copy(CFF, privOff, privSz));
    defW := Round(DictGet(privDict, 20, 0, 0));
    nomW := Round(DictGet(privDict, 21, 0, 0));
  end;

  SetLength(gidWidth, numGlyphs);
  SetLength(uniToGid, $10000);
  for i := 0 to High(uniToGid) do uniToGid[i] := -1;

  // charset: GID -> SID -> Unicode
  if charsetOff > 2 then
  begin
    fmt := RdU8(CFF, charsetOff);
    g := 1;
    i := charsetOff + 1;
    if fmt = 0 then
    begin
      while (g < numGlyphs) and (i+1 < Length(CFF)) do
      begin
        sid := RdU16(CFF, i);
        Inc(i,2);
        if sid < 391 then uni := StdUni[sid]
        else begin
          so := IndexObj(CFF, strIdx, sid-391);
          SetLength(nm,Length(so));
          for m:=0 to High(so) do nm[m+1]:=AnsiChar(so[m]);
          uni := NameToUnicode(nm);
        end;
        if (uni > 0) and (uni <= $FFFF) then uniToGid[uni] := g;
        Inc(g);
      end;
    end
    else if (fmt = 1) or (fmt = 2) then
    begin
      while (g < numGlyphs) and (i < Length(CFF)) do
      begin
        first := RdU16(CFF, i);
        Inc(i,2);
        if fmt = 1 then begin
          nLeft := RdU8(CFF,i);
          Inc(i);
        end else begin
          nLeft := RdU16(CFF,i);
          Inc(i,2);
        end;
        for k := 0 to nLeft do
        begin
          if g >= numGlyphs then Break;
          sid := first + k;
          if sid < 391 then uni := StdUni[sid]
          else begin
            so := IndexObj(CFF, strIdx, sid-391);
            SetLength(nm,Length(so));
            for m:=0 to High(so) do nm[m+1]:=AnsiChar(so[m]);
            uni := NameToUnicode(nm);
          end;
          if (uni > 0) and (uni <= $FFFF) then uniToGid[uni] := g;
          Inc(g);
        end;
      end;
    end;
  end
  else
  begin
    for g := 1 to numGlyphs-1 do
      if g < 391 then begin
        uni := StdUni[g];
        if (uni>0) and (uni<=$FFFF) then uniToGid[uni] := g;
      end;
  end;

  // advance widths
  maxAdv := 0;
  avgW := 0;
  for gid := 0 to numGlyphs-1 do
  begin
    csObj := IndexObj(CFF, csIdx, gid);
    gidWidth[gid] := CharstringWidth(csObj, defW, nomW);
    if gidWidth[gid] < 0 then gidWidth[gid] := 0;
    if gidWidth[gid] > maxAdv then maxAdv := gidWidth[gid];
    avgW := avgW + gidWidth[gid];
  end;
  if numGlyphs > 0 then avgW := avgW div numGlyphs;

  SetLength(segU, 0);
  nSeg := 0;
  minU := $FFFF;
  maxU := 0;
  for i := 0 to High(uniToGid) do
    if uniToGid[i] >= 0 then
    begin
      SetLength(segU, nSeg+1);
      segU[nSeg] := i;
      Inc(nSeg);
      if i < minU then minU := i;
      if i > maxU then maxU := i;
    end;
  if nSeg = 0 then begin
    minU := 0;
    maxU := 0;
  end;

  asc := Round(unitsPerEm*0.8);
  desc := -Round(unitsPerEm*0.2);
  winAsc := Round(unitsPerEm*0.9);
  winDesc := Round(unitsPerEm*0.25);
  psName := StringReplace(string(FamilyName), ' ', '', [rfReplaceAll]);

  cffT := TMemoryStream.Create;
  os2T := TMemoryStream.Create;
  cmapT := TMemoryStream.Create;
  headT := TMemoryStream.Create;
  hheaT := TMemoryStream.Create;
  hmtxT := TMemoryStream.Create;
  maxpT := TMemoryStream.Create;
  nameT := TMemoryStream.Create;
  postT := TMemoryStream.Create;
  out_ := TMemoryStream.Create;
  try
    if Length(CFF) > 0 then cffT.WriteBuffer(CFF[0], Length(CFF));

    // head
    W16(headT,1);
    W16(headT,0);
    W32(headT,$00010000);
    W32(headT,0);
    W32(headT,$5F0F3CF5);
    W16(headT,$000B);
    W16(headT,unitsPerEm);
    W32(headT,0);
    W32(headT,0);
    W32(headT,0);
    W32(headT,0);
    W16i(headT,0);
    W16i(headT,desc);
    W16i(headT,maxAdv);
    W16i(headT,asc);
    W16(headT,0);
    W16(headT,8);
    W16i(headT,2);
    W16(headT,0);
    W16(headT,0);

    // hhea
    W16(hheaT,1);
    W16(hheaT,0);
    W16i(hheaT,asc);
    W16i(hheaT,desc);
    W16(hheaT,0);
    W16(hheaT,maxAdv);
    W16(hheaT,0);
    W16(hheaT,0);
    W16i(hheaT,maxAdv);
    W16(hheaT,1);
    W16(hheaT,0);
    W16(hheaT,0);
    W16(hheaT,0);
    W16(hheaT,0);
    W16(hheaT,0);
    W16(hheaT,0);
    W16(hheaT,0);
    W16(hheaT,numGlyphs);

    // hmtx
    for gid := 0 to numGlyphs-1 do begin
      W16(hmtxT, Word(gidWidth[gid] and $FFFF));
      W16(hmtxT,0);
    end;

    // maxp
    W32(maxpT,$00005000);
    W16(maxpT,numGlyphs);

    // OS/2 v4
    W16(os2T,4);
    W16i(os2T,avgW);
    W16(os2T,400);
    W16(os2T,5);
    W16(os2T,0);
    W16i(os2T,Round(unitsPerEm*0.65));
    W16i(os2T,Round(unitsPerEm*0.7));
    W16(os2T,0);
    W16i(os2T,Round(unitsPerEm*0.14));
    W16i(os2T,Round(unitsPerEm*0.65));
    W16i(os2T,Round(unitsPerEm*0.7));
    W16(os2T,0);
    W16i(os2T,Round(unitsPerEm*0.48));
    W16i(os2T,Round(unitsPerEm*0.05));
    W16i(os2T,Round(unitsPerEm*0.26));
    W16(os2T,0);
    for i := 0 to 9 do W8(os2T,0);
    W32(os2T,$00000003);
    W32(os2T,0);
    W32(os2T,0);
    W32(os2T,0);
    WTag(os2T,'PDFr');
    W16(os2T,$0040);
    W16(os2T,minU);
    W16(os2T,maxU);
    W16i(os2T,asc);
    W16i(os2T,desc);
    W16(os2T,0);
    W16(os2T,winAsc);
    W16(os2T,winDesc);
    W32(os2T,$00000001);
    W32(os2T,0);
    W16i(os2T,Round(unitsPerEm*0.5));
    W16i(os2T,Round(unitsPerEm*0.7));
    W16(os2T,0);
    W16(os2T,$20);
    W16(os2T,1);

    // post v3
    W32(postT,$00030000);
    W32(postT,0);
    W16i(postT,-Round(unitsPerEm*0.1));
    W16i(postT,Round(unitsPerEm*0.05));
    W32(postT,0);
    W32(postT,0);
    W32(postT,0);
    W32(postT,0);
    W32(postT,0);

    // cmap (3,1) format 4
    segCount := nSeg + 1;
    entrySel := 0;
    t := 1;
    while (t*2) <= segCount do begin
      t := t*2;
      Inc(entrySel);
    end;
    searchRange := 2*t;
    rangeShift := 2*segCount - searchRange;
    W16(cmapT,0);
    W16(cmapT,1);
    W16(cmapT,3);
    W16(cmapT,1);
    W32(cmapT,12);
    W16(cmapT,4);
    W16(cmapT, 16 + segCount*8);
    W16(cmapT,0);
    W16(cmapT, segCount*2);
    W16(cmapT, searchRange);
    W16(cmapT, entrySel);
    W16(cmapT, rangeShift);
    for j := 0 to nSeg-1 do W16(cmapT, segU[j]);
    W16(cmapT, $FFFF);
    W16(cmapT,0);
    for j := 0 to nSeg-1 do W16(cmapT, segU[j]);
    W16(cmapT, $FFFF);
    for j := 0 to nSeg-1 do W16(cmapT, Word((uniToGid[segU[j]] - segU[j]) and $FFFF));
    W16(cmapT, 1);
    for j := 0 to segCount-1 do W16(cmapT, 0);

    BuildName(nameT, FamilyName, psName);

    tabB[0]:=StreamBytes(cffT);
    tabTag[0]:='CFF ';
    tabB[1]:=StreamBytes(os2T);
    tabTag[1]:='OS/2';
    tabB[2]:=StreamBytes(cmapT);
    tabTag[2]:='cmap';
    tabB[3]:=StreamBytes(headT);
    tabTag[3]:='head';
    tabB[4]:=StreamBytes(hheaT);
    tabTag[4]:='hhea';
    tabB[5]:=StreamBytes(hmtxT);
    tabTag[5]:='hmtx';
    tabB[6]:=StreamBytes(maxpT);
    tabTag[6]:='maxp';
    tabB[7]:=StreamBytes(nameT);
    tabTag[7]:='name';
    tabB[8]:=StreamBytes(postT);
    tabTag[8]:='post';
    numTables := 9;

    entrySel := 0;
    t := 1;
    while (t*2) <= numTables do begin
      t := t*2;
      Inc(entrySel);
    end;
    searchRange := t*16;
    rangeShift := numTables*16 - searchRange;
    WTag(out_,'OTTO');
    W16(out_,numTables);
    W16(out_,searchRange);
    W16(out_,entrySel);
    W16(out_,rangeShift);

    off := 12 + numTables*16;
    headOffInFont := 0;
    for k := 0 to numTables-1 do
    begin
      WTag(out_, tabTag[k]);
      W32(out_, TableChecksum(Pad4(tabB[k])));
      W32(out_, off);
      W32(out_, Length(tabB[k]));
      if tabTag[k] = 'head' then headOffInFont := off;
      off := off + Length(Pad4(tabB[k]));
    end;
    for k := 0 to numTables-1 do
    begin
      fontB := Pad4(tabB[k]);
      if Length(fontB) > 0 then out_.WriteBuffer(fontB[0], Length(fontB));
    end;

    fontB := Pad4(StreamBytes(out_));
    adj := $B1B0AFBA - TableChecksum(fontB);
    savedPos := out_.Position;
    out_.Position := headOffInFont + 8;
    W32(out_, adj);
    out_.Position := savedPos;

    SetLength(Result, out_.Size);
    if out_.Size > 0 then Move(out_.Memory^, Result[0], out_.Size);
  finally
    cffT.Free;
    os2T.Free;
    cmapT.Free;
    headT.Free;
    hheaT.Free;
    hmtxT.Free;
    maxpT.Free;
    nameT.Free;
    postT.Free;
    out_.Free;
  end;
end;

// Assemble an SFNT from tables (sorted by tag), fixing offsets/checksums and
// head.checkSumAdjustment. Datas[k] is the raw (unpadded) table content.
function AssembleSFNT(Tags: array of AnsiString; Datas: array of TBytes; sfntVer: LongWord): TPdfBytes;
var
  out_: TMemoryStream;
  n, k, j, off, entrySel, searchRange, rangeShift, t, headOff: Integer;
  ti: AnsiString;
  td: TBytes;
  padded: array of TBytes;
  fontB: TBytes;
  adj: LongWord;
  savedPos: Int64;
begin
  Result := nil;
  n := Length(Tags);
  if n = 0 then Exit;
  // Insertion-sort tables by tag (the directory must be in ascending tag order).
  for k := 1 to n-1 do
  begin
    ti := Tags[k];
    td := Datas[k];
    j := k-1;
    while (j >= 0) and (Tags[j] > ti) do begin
      Tags[j+1] := Tags[j];
      Datas[j+1] := Datas[j];
      Dec(j);
    end;
    Tags[j+1] := ti;
    Datas[j+1] := td;
  end;
  SetLength(padded, n);
  for k := 0 to n-1 do padded[k] := Pad4(Datas[k]);
  out_ := TMemoryStream.Create;
  try
    entrySel := 0;
    t := 1;
    while (t*2) <= n do begin
      t := t*2;
      Inc(entrySel);
    end;
    searchRange := t*16;
    rangeShift := n*16 - searchRange;
    W32(out_, sfntVer);
    W16(out_, n);
    W16(out_, searchRange);
    W16(out_, entrySel);
    W16(out_, rangeShift);
    off := 12 + n*16;
    headOff := -1;
    for k := 0 to n-1 do
    begin
      WTag(out_, Tags[k]);
      W32(out_, TableChecksum(padded[k]));
      W32(out_, off);
      W32(out_, Length(Datas[k]));
      if Tags[k] = 'head' then headOff := off;
      off := off + Length(padded[k]);
    end;
    for k := 0 to n-1 do
      if Length(padded[k]) > 0 then out_.WriteBuffer(padded[k][0], Length(padded[k]));
    if headOff >= 0 then
    begin
      fontB := Pad4(StreamBytes(out_));
      adj := $B1B0AFBA - TableChecksum(fontB);
      savedPos := out_.Position;
      out_.Position := headOff + 8;
      W32(out_, adj);
      out_.Position := savedPos;
    end;
    SetLength(Result, out_.Size);
    if out_.Size > 0 then Move(out_.Memory^, Result[0], out_.Size);
  finally
    out_.Free;
  end;
end;

function EnsureFontTables(const Font: TPdfBytes): TPdfBytes;
var
  n, i, off, len, numGlyphs, lastChar: Integer;
  tag: AnsiString;
  Tags: array of AnsiString;
  Datas: array of TBytes;
  hasCmap, hasPost: Boolean;
  td, cmapD, postD: TBytes;
  ms: TMemoryStream;
begin
  Result := Font;
  if Length(Font) < 12 then Exit;
  n := RdU16(Font, 4);
  if (n <= 0) or (12 + n*16 > Length(Font)) then Exit;
  hasCmap := False;
  hasPost := False;
  numGlyphs := 0;
  SetLength(Tags, 0);
  SetLength(Datas, 0);
  for i := 0 to n-1 do
  begin
    tag := AnsiChar(Font[12+i*16+0]) + AnsiChar(Font[12+i*16+1]) +
           AnsiChar(Font[12+i*16+2]) + AnsiChar(Font[12+i*16+3]);
    off := Integer(RdU32(Font, 12+i*16+8));
    len := Integer(RdU32(Font, 12+i*16+12));
    if (off < 0) or (len < 0) or (off+len > Length(Font)) then Continue;
    SetLength(td, len);
    if len > 0 then Move(Font[off], td[0], len);
    SetLength(Tags, Length(Tags)+1);
    Tags[High(Tags)] := tag;
    SetLength(Datas, Length(Datas)+1);
    Datas[High(Datas)] := td;
    if tag = 'cmap' then hasCmap := True;
    if tag = 'post' then hasPost := True;
    if (tag = 'maxp') and (len >= 6) then numGlyphs := RdU16(td, 4);
  end;
  if hasCmap and hasPost then Exit;  // already complete

  if not hasCmap then
  begin
    // Minimal (3,1) format-4 cmap: one segment mapping char (0x20+i) -> GID i,
    // so Windows can preview/install the subset's glyphs (idDelta = -0x20).
    if numGlyphs < 1 then numGlyphs := 1;
    lastChar := $20 + numGlyphs - 1;
    if lastChar > $FFFE then lastChar := $FFFE;
    ms := TMemoryStream.Create;
    try
      W16(ms,0);
      W16(ms,1);  // version, numTables
      W16(ms,3);
      W16(ms,1);
      W32(ms,12);  // (3,1) -> subtable at 12
      W16(ms,4);  // format 4
      W16(ms, 16 + 8*2);  // length (segCount=2)
      W16(ms,0);  // language
      W16(ms, 2*2);  // segCountX2
      W16(ms, 4);
      W16(ms, 1);
      W16(ms, 0);  // searchRange, entrySel, rangeShift (segCount=2)
      W16(ms, lastChar);
      W16(ms, $FFFF);  // endCode
      W16(ms, 0);  // reservedPad
      W16(ms, $20);
      W16(ms, $FFFF);  // startCode
      W16(ms, Word($FFE0));
      W16(ms, 1);  // idDelta (-0x20), 1
      W16(ms, 0);
      W16(ms, 0);  // idRangeOffset
      cmapD := StreamBytes(ms);
    finally
      ms.Free;
    end;
    SetLength(Tags, Length(Tags)+1);
    Tags[High(Tags)] := 'cmap';
    SetLength(Datas, Length(Datas)+1);
    Datas[High(Datas)] := cmapD;
  end;

  if not hasPost then
  begin
    ms := TMemoryStream.Create;
    try
      W32(ms, $00030000);  // version 3.0 (no glyph names)
      W32(ms, 0);  // italicAngle
      W16(ms, Word(SmallInt(-100)));
      W16(ms, 50);  // underline pos/thick
      W32(ms, 0);  // isFixedPitch
      W32(ms, 0);
      W32(ms, 0);
      W32(ms, 0);
      W32(ms, 0);  // mem usage
      postD := StreamBytes(ms);
    finally
      ms.Free;
    end;
    SetLength(Tags, Length(Tags)+1);
    Tags[High(Tags)] := 'post';
    SetLength(Datas, Length(Datas)+1);
    Datas[High(Datas)] := postD;
  end;

  Result := AssembleSFNT(Tags, Datas, LongWord(RdU32(Font, 0)));
  if Length(Result) = 0 then Result := Font;
end;

procedure InitStdUni;
var i: Integer;
  procedure U(sid: Integer; u: Word);
  begin
    StdUni[sid] := u;
  end;
begin
  for i := 0 to 390 do StdUni[i] := 0;
  U(1,$20);
  U(2,$21);
  U(3,$22);
  U(4,$23);
  U(5,$24);
  U(6,$25);
  U(7,$26);
  U(8,$2019);
  U(9,$28);
  U(10,$29);
  U(11,$2A);
  U(12,$2B);
  U(13,$2C);
  U(14,$2D);
  U(15,$2E);
  U(16,$2F);
  for i := 0 to 9 do U(17+i, $30+i);
  U(27,$3A);
  U(28,$3B);
  U(29,$3C);
  U(30,$3D);
  U(31,$3E);
  U(32,$3F);
  U(33,$40);
  for i := 0 to 25 do U(34+i, $41+i);
  U(60,$5B);
  U(61,$5C);
  U(62,$5D);
  U(63,$5E);
  U(64,$5F);
  U(65,$2018);
  for i := 0 to 25 do U(66+i, $61+i);
  U(92,$7B);
  U(93,$7C);
  U(94,$7D);
  U(95,$7E);
  U(96,$A1);
  U(97,$A2);
  U(98,$A3);
  U(99,$2044);
  U(100,$A5);
  U(101,$192);
  U(102,$A7);
  U(103,$A4);
  U(104,$27);
  U(105,$201C);
  U(106,$AB);
  U(107,$2039);
  U(108,$203A);
  U(109,$FB01);
  U(110,$FB02);
  U(111,$2013);
  U(112,$2020);
  U(113,$2021);
  U(114,$B7);
  U(115,$B6);
  U(116,$2022);
  U(117,$201A);
  U(118,$201E);
  U(119,$201D);
  U(120,$BB);
  U(121,$2026);
  U(122,$2030);
  U(123,$BF);
  U(124,$60);
  U(125,$B4);
  U(126,$2C6);
  U(127,$2DC);
  U(128,$AF);
  U(129,$2D8);
  U(130,$2D9);
  U(131,$A8);
  U(132,$2DA);
  U(133,$B8);
  U(134,$2DD);
  U(135,$2DB);
  U(136,$2C7);
  U(137,$2014);
  U(138,$C6);
  U(139,$AA);
  U(140,$141);
  U(141,$D8);
  U(142,$152);
  U(143,$BA);
  U(144,$E6);
  U(145,$131);
  U(146,$142);
  U(147,$F8);
  U(148,$153);
  U(149,$DF);
  U(150,$B9);
  U(151,$AC);
  U(152,$B5);
  U(153,$2122);
  U(154,$D0);
  U(155,$BD);
  U(156,$B1);
  U(157,$DE);
  U(158,$BC);
  U(159,$F7);
  U(160,$A6);
  U(161,$B0);
  U(162,$FE);
  U(163,$BE);
  U(164,$B2);
  U(165,$AE);
  U(166,$2212);
  U(167,$F0);
  U(168,$D7);
  U(169,$B3);
  U(170,$A9);
  U(171,$C1);
  U(172,$C2);
  U(173,$C4);
  U(174,$C0);
  U(175,$C5);
  U(176,$C3);
  U(177,$C7);
  U(178,$C9);
  U(179,$CA);
  U(180,$CB);
  U(181,$C8);
  U(182,$CD);
  U(183,$CE);
  U(184,$CF);
  U(185,$CC);
  U(186,$D1);
  U(187,$D3);
  U(188,$D4);
  U(189,$D6);
  U(190,$D2);
  U(191,$D5);
  U(192,$160);
  U(193,$DA);
  U(194,$DB);
  U(195,$DC);
  U(196,$D9);
  U(197,$DD);
  U(198,$178);
  U(199,$17D);
  U(200,$E1);
  U(201,$E2);
  U(202,$E4);
  U(203,$E0);
  U(204,$E5);
  U(205,$E3);
  U(206,$E7);
  U(207,$E9);
  U(208,$EA);
  U(209,$EB);
  U(210,$E8);
  U(211,$ED);
  U(212,$EE);
  U(213,$EF);
  U(214,$EC);
  U(215,$F1);
  U(216,$F3);
  U(217,$F4);
  U(218,$F6);
  U(219,$F2);
  U(220,$F5);
  U(221,$161);
  U(222,$FA);
  U(223,$FB);
  U(224,$FC);
  U(225,$F9);
  U(226,$FD);
  U(227,$FF);
  U(228,$17E);
end;

initialization
  InitStdUni;
end.
