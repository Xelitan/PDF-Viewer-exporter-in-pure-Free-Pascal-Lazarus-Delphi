unit PdfObjects;
{$mode delphi}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
interface
uses SysUtils, Classes, Contnrs, PdfTypes;

type
  TPdfObjectKind = (pokNull, pokBoolean, pokInteger, pokReal, pokName, pokString,
    pokArray, pokDictionary, pokStream, pokReference);

  TPdfObject = class
  public
    Kind: TPdfObjectKind;
    function AsName: string;
    virtual;
    function AsString: AnsiString;
    virtual;
    function AsNumber: Double;
    virtual;
  end;

  TPdfNumberObject = class(TPdfObject)
  public
    Value: Double;
    constructor Create(AValue: Double; AKind: TPdfObjectKind);
    function AsNumber: Double;
    override;
  end;

  TPdfNameObject = class(TPdfObject)
  public
    Value: string;
    constructor Create(const AValue: string);
    function AsName: string;
    override;
  end;

  TPdfStringObject = class(TPdfObject)
  public
    Value: AnsiString;
    constructor Create(const AValue: AnsiString);
    function AsString: AnsiString;
    override;
  end;

  TPdfArrayObject = class(TPdfObject)
  public
    Items: TObjectList;
    constructor Create;
    destructor Destroy;
    override;
  end;

  TPdfDictionaryObject = class(TPdfObject)
  public
    Keys: TStringList;
    constructor Create;
    destructor Destroy;
    override;
    procedure Add(const Key: string; Obj: TPdfObject);
    function Get(const Key: string): TPdfObject;
    function GetName(const Key: string): string;
    function GetNumber(const Key: string; Default: Double = 0): Double;
  end;

  TPdfStreamObject = class(TPdfDictionaryObject)
  public
    RawData: TPdfBytes;
    DecodedData: TPdfBytes;
    constructor Create;
  end;

  TPdfReferenceObject = class(TPdfObject)
  public
    ObjectNumber: Integer;
    Generation: Integer;
    constructor Create(AObjNum, AGen: Integer);
  end;

  // Callback used to resolve indirect-reference objects from the XRef table.
  // Passed to font-loading routines so they can dereference 16 0 R etc.
  TPdfObjectResolver = function(Obj: TPdfObject): TPdfObject of object;

implementation

function TPdfObject.AsName: string;
begin
  Result := '';
end;
function TPdfObject.AsString: AnsiString;
begin
  Result := '';
end;
function TPdfObject.AsNumber: Double;
begin
  Result := 0;
end;

constructor TPdfNumberObject.Create(AValue: Double; AKind: TPdfObjectKind);
begin
  inherited Create;
  Kind := AKind;
  Value := AValue;
end;
function TPdfNumberObject.AsNumber: Double;
begin
  Result := Value;
end;

constructor TPdfNameObject.Create(const AValue: string);
begin
  inherited Create;
  Kind := pokName;
  Value := AValue;
end;
function TPdfNameObject.AsName: string;
begin
  Result := Value;
end;

constructor TPdfStringObject.Create(const AValue: AnsiString);
begin
  inherited Create;
  Kind := pokString;
  Value := AValue;
end;
function TPdfStringObject.AsString: AnsiString;
begin
  Result := Value;
end;

constructor TPdfArrayObject.Create;
begin
  inherited Create;
  Kind := pokArray;
  Items := TObjectList.Create(True);
end;
destructor TPdfArrayObject.Destroy;
begin
  Items.Free;
  inherited Destroy;
end;

constructor TPdfDictionaryObject.Create;
begin
  inherited Create;
  Kind := pokDictionary;
  Keys := TStringList.Create;
  Keys.OwnsObjects := True;
end;
destructor TPdfDictionaryObject.Destroy;
begin
  Keys.Free;
  inherited Destroy;
end;
procedure TPdfDictionaryObject.Add(const Key: string; Obj: TPdfObject);
var I: Integer;
begin
  I := Keys.IndexOf(Key);
  if I >= 0 then Keys.Objects[I] := Obj else Keys.AddObject(Key, Obj);
end;
function TPdfDictionaryObject.Get(const Key: string): TPdfObject;
var I: Integer;
begin
  I := Keys.IndexOf(Key);
  if I >= 0 then Result := TPdfObject(Keys.Objects[I]) else Result := nil;
end;
function TPdfDictionaryObject.GetName(const Key: string): string;
var O: TPdfObject;
begin
  O := Get(Key);
  if Assigned(O) then Result := O.AsName else Result := '';
end;
function TPdfDictionaryObject.GetNumber(const Key: string; Default: Double): Double;
var O: TPdfObject;
begin
  O := Get(Key);
  if Assigned(O) then Result := O.AsNumber else Result := Default;
end;

constructor TPdfStreamObject.Create;
begin
  inherited Create;
  Kind := pokStream;
end;

constructor TPdfReferenceObject.Create(AObjNum, AGen: Integer);
begin
  inherited Create;
  Kind := pokReference;
  ObjectNumber := AObjNum;
  Generation := AGen;
end;

end.
