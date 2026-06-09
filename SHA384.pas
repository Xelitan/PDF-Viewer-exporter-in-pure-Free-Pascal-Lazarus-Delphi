unit SHA384;
{$mode delphi}{$H+}{$R-}{$Q-}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
//SHA-384 (SHA-2). Same core as SHA-512 with different IVs and a 48-byte output
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

interface

uses SysUtils;

function SHA384(Msg: PByte; Len: PtrInt): TBytes;  // raw 48-byte digest
function SHA384Hex(Msg: PByte; Len: PtrInt): String;

implementation

const K: array[0..79] of QWord = (
  $428A2F98D728AE22, $7137449123EF65CD, $B5C0FBCFEC4D3B2F, $E9B5DBA58189DBBC,
  $3956C25BF348B538, $59F111F1B605D019, $923F82A4AF194F9B, $AB1C5ED5DA6D8118,
  $D807AA98A3030242, $12835B0145706FBE, $243185BE4EE4B28C, $550C7DC3D5FFB4E2,
  $72BE5D74F27B896F, $80DEB1FE3B1696B1, $9BDC06A725C71235, $C19BF174CF692694,
  $E49B69C19EF14AD2, $EFBE4786384F25E3, $0FC19DC68B8CD5B5, $240CA1CC77AC9C65,
  $2DE92C6F592B0275, $4A7484AA6EA6E483, $5CB0A9DCBD41FBD4, $76F988DA831153B5,
  $983E5152EE66DFAB, $A831C66D2DB43210, $B00327C898FB213F, $BF597FC7BEEF0EE4,
  $C6E00BF33DA88FC2, $D5A79147930AA725, $06CA6351E003826F, $142929670A0E6E70,
  $27B70A8546D22FFC, $2E1B21385C26C926, $4D2C6DFC5AC42AED, $53380D139D95B3DF,
  $650A73548BAF63DE, $766A0ABB3C77B2A8, $81C2C92E47EDAEE6, $92722C851482353B,
  $A2BFE8A14CF10364, $A81A664BBC423001, $C24B8B70D0F89791, $C76C51A30654BE30,
  $D192E819D6EF5218, $D69906245565A910, $F40E35855771202A, $106AA07032BBD1B8,
  $19A4C116B8D2D0C8, $1E376C085141AB53, $2748774CDF8EEB99, $34B0BCB5E19B48A8,
  $391C0CB3C5C95A63, $4ED8AA4AE3418ACB, $5B9CCA4F7763E373, $682E6FF3D6B2B8A3,
  $748F82EE5DEFB2FC, $78A5636F43172F60, $84C87814A1F0AB72, $8CC702081A6439EC,
  $90BEFFFA23631E28, $A4506CEBDE82BDE9, $BEF9A3F7B2C67915, $C67178F2E372532B,
  $CA273ECEEA26619C, $D186B8C721C0C207, $EADA7DD6CDE0EB1E, $F57D4F7FEE6ED178,
  $06F067AA72176FBA, $0A637DC5A2C898A6, $113F9804BEF90DAE, $1B710B35131C471B,
  $28DB77F523047D84, $32CAAB7B40C72493, $3C9EBE0A15C9BEBC, $431D67C49C100D4C,
  $4CC5D4BECB3E42B6, $597F299CFC657E2A, $5FCB6FAB3AD6FAEC, $6C44198C4A475817
);

procedure Compress(var H: array of QWord; Block: PByte);
var w: array[0..79] of QWord;
  r,i: Integer;
    a,b,c,d,e,f,g,hh, s0,s1,t1,t2: QWord;
begin
  for i := 0 to 15 do
    w[i] := (QWord(Block[i*8]) shl 56) or (QWord(Block[i*8+1]) shl 48)
         or (QWord(Block[i*8+2]) shl 40) or (QWord(Block[i*8+3]) shl 32)
         or (QWord(Block[i*8+4]) shl 24) or (QWord(Block[i*8+5]) shl 16)
         or (QWord(Block[i*8+6]) shl 8) or QWord(Block[i*8+7]);
  for r := 16 to 79 do
  begin
    s0 := RorQWord(w[r-15],1) xor RorQWord(w[r-15],8) xor (w[r-15] shr 7);
    s1 := RorQWord(w[r-2],19) xor RorQWord(w[r-2],61) xor (w[r-2] shr 6);
    w[r] := w[r-16] + s0 + w[r-7] + s1;
  end;
  a:=H[0];
  b:=H[1];
  c:=H[2];
  d:=H[3];
  e:=H[4];
  f:=H[5];
  g:=H[6];
  hh:=H[7];
  for r := 0 to 79 do
  begin
    t1 := hh + (RorQWord(e,14) xor RorQWord(e,18) xor RorQWord(e,41))
            + ((e and f) xor ((not e) and g)) + K[r] + w[r];
    t2 := (RorQWord(a,28) xor RorQWord(a,34) xor RorQWord(a,39))
            + ((a and b) xor (a and c) xor (b and c));
    hh:=g;
    g:=f;
    f:=e;
    e:=d+t1;
    d:=c;
    c:=b;
    b:=a;
    a:=t1+t2;
  end;
  H[0]:=H[0]+a;
  H[1]:=H[1]+b;
  H[2]:=H[2]+c;
  H[3]:=H[3]+d;
  H[4]:=H[4]+e;
  H[5]:=H[5]+f;
  H[6]:=H[6]+g;
  H[7]:=H[7]+hh;
end;

function SHA384(Msg: PByte; Len: PtrInt): TBytes;
var H: array[0..7] of QWord;
  buf: TBytes;
  padLen, i: PtrInt;
  bits: QWord;
begin
  H[0]:=QWord($CBBB9D5DC1059ED8);
  H[1]:=QWord($629A292A367CD507);
  H[2]:=QWord($9159015A3070DD17);
  H[3]:=QWord($152FECD8F70E5939);
  H[4]:=QWord($67332667FFC00B31);
  H[5]:=QWord($8EB44A8768581511);
  H[6]:=QWord($DB0C2E0D64F98FA7);
  H[7]:=QWord($47B5481DBEFA4FA4);
  padLen := Len + 1;
  while (padLen mod 128) <> 112 do Inc(padLen);
  Inc(padLen, 16);
  SetLength(buf, padLen);
  if Len > 0 then Move(Msg^, buf[0], Len);
  buf[Len] := $80;
  bits := QWord(Len) shl 3;
  for i := 0 to 7 do buf[padLen-1-i] := Byte(bits shr (8*i));
  i := 0;
  while i < padLen do begin
    Compress(H, @buf[i]);
    Inc(i, 128);
  end;
  SetLength(Result, 48);  // SHA-384 truncates to the first 6 words
  for i := 0 to 5 do
  begin
    Result[i*8]   := Byte(H[i] shr 56);
    Result[i*8+1] := Byte(H[i] shr 48);
    Result[i*8+2] := Byte(H[i] shr 40);
    Result[i*8+3] := Byte(H[i] shr 32);
    Result[i*8+4] := Byte(H[i] shr 24);
    Result[i*8+5] := Byte(H[i] shr 16);
    Result[i*8+6] := Byte(H[i] shr 8);
    Result[i*8+7] := Byte(H[i]);
  end;
end;

function SHA384Hex(Msg: PByte; Len: PtrInt): String;
var d: TBytes;
  i: Integer;
begin
  d := SHA384(Msg, Len);
  Result := '';
  for i := 0 to High(d) do Result := Result + IntToHex(d[i], 2);
end;

end.
