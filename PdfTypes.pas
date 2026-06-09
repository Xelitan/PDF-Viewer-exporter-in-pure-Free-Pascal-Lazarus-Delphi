unit PdfTypes;
{$mode delphi}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
interface
uses SysUtils, Classes;

type
  TPdfBytes = TBytes;

  TPdfRect = record
    X1, Y1, X2, Y2: Double;
  end;

  TPdfMatrix = record
    A, B, C, D, E, F: Double;
  end;

function PdfIdentityMatrix: TPdfMatrix;
function PdfMatrixMultiply(const L, R: TPdfMatrix): TPdfMatrix;
function PdfMatrixTranslate(Tx, Ty: Double): TPdfMatrix;
function PdfMatrixScale(Sx, Sy: Double): TPdfMatrix;
function PdfMatrixFrom(A, B, C, D, E, F: Double): TPdfMatrix;

implementation

function PdfIdentityMatrix: TPdfMatrix;
begin
  Result.A := 1;
  Result.B := 0;
  Result.C := 0;
  Result.D := 1;
  Result.E := 0;
  Result.F := 0;
end;

function PdfMatrixFrom(A, B, C, D, E, F: Double): TPdfMatrix;
begin
  Result.A := A;
  Result.B := B;
  Result.C := C;
  Result.D := D;
  Result.E := E;
  Result.F := F;
end;

function PdfMatrixMultiply(const L, R: TPdfMatrix): TPdfMatrix;
begin
  Result.A := L.A * R.A + L.B * R.C;
  Result.B := L.A * R.B + L.B * R.D;
  Result.C := L.C * R.A + L.D * R.C;
  Result.D := L.C * R.B + L.D * R.D;
  Result.E := L.E * R.A + L.F * R.C + R.E;
  Result.F := L.E * R.B + L.F * R.D + R.F;
end;

function PdfMatrixTranslate(Tx, Ty: Double): TPdfMatrix;
begin
  Result := PdfIdentityMatrix;
  Result.E := Tx;
  Result.F := Ty;
end;

function PdfMatrixScale(Sx, Sy: Double): TPdfMatrix;
begin
  Result := PdfIdentityMatrix;
  Result.A := Sx;
  Result.D := Sy;
end;

end.
