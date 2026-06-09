unit SHA256;
{$mode delphi}{$H+}{$R-}{$Q-}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
interface

uses SysUtils;

// Raw 32-byte SHA-256 digest of Len bytes at Msg.
function SHA256(Msg: PByte; Len: PtrInt): TBytes;
// Convenience hex form (uppercase).
function SHA256Hex(Msg: PByte; Len: PtrInt): String;

implementation

const K: array[0..63] of Cardinal = (
  $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
  $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
  $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
  $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
  $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
  $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
  $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
  $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2
);

procedure Compress(var H: array of Cardinal; Block: PByte);
var w: array[0..63] of Cardinal;
  i: Integer;
    a,b,c,d,e,f,g,hh, s0,s1, ch,maj,t1,t2: Cardinal;
begin
  for i := 0 to 15 do
    w[i] := (Cardinal(Block[i*4]) shl 24) or (Cardinal(Block[i*4+1]) shl 16)
         or (Cardinal(Block[i*4+2]) shl 8) or Cardinal(Block[i*4+3]);
  for i := 16 to 63 do
  begin
    s0 := RorDWord(w[i-15],7) xor RorDWord(w[i-15],18) xor (w[i-15] shr 3);
    s1 := RorDWord(w[i-2],17) xor RorDWord(w[i-2],19) xor (w[i-2] shr 10);
    w[i] := w[i-16] + s0 + w[i-7] + s1;
  end;
  a:=H[0];
  b:=H[1];
  c:=H[2];
  d:=H[3];
  e:=H[4];
  f:=H[5];
  g:=H[6];
  hh:=H[7];
  for i := 0 to 63 do
  begin
    s1 := RorDWord(e,6) xor RorDWord(e,11) xor RorDWord(e,25);
    ch := (e and f) xor ((not e) and g);
    t1 := hh + s1 + ch + K[i] + w[i];
    s0 := RorDWord(a,2) xor RorDWord(a,13) xor RorDWord(a,22);
    maj := (a and b) xor (a and c) xor (b and c);
    t2 := s0 + maj;
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

function SHA256(Msg: PByte; Len: PtrInt): TBytes;
var H: array[0..7] of Cardinal;
  buf: TBytes;
  padLen, i: PtrInt;
  bits: QWord;
begin
  H[0]:=$6a09e667;
  H[1]:=$bb67ae85;
  H[2]:=$3c6ef372;
  H[3]:=$a54ff53a;
  H[4]:=$510e527f;
  H[5]:=$9b05688c;
  H[6]:=$1f83d9ab;
  H[7]:=$5be0cd19;
  padLen := Len + 1;
  while (padLen mod 64) <> 56 do Inc(padLen);
  Inc(padLen, 8);
  SetLength(buf, padLen);  // dynamic arrays are zero-filled
  if Len > 0 then Move(Msg^, buf[0], Len);
  buf[Len] := $80;
  bits := QWord(Len) shl 3;
  for i := 0 to 7 do buf[padLen-1-i] := Byte(bits shr (8*i));
  i := 0;
  while i < padLen do begin
    Compress(H, @buf[i]);
    Inc(i, 64);
  end;
  SetLength(Result, 32);
  for i := 0 to 7 do
  begin
    Result[i*4]   := Byte(H[i] shr 24);
    Result[i*4+1] := Byte(H[i] shr 16);
    Result[i*4+2] := Byte(H[i] shr 8);
    Result[i*4+3] := Byte(H[i]);
  end;
end;

function SHA256Hex(Msg: PByte; Len: PtrInt): String;
var d: TBytes;
  i: Integer;
begin
  d := SHA256(Msg, Len);
  Result := '';
  for i := 0 to High(d) do Result := Result + IntToHex(d[i], 2);
end;

end.
