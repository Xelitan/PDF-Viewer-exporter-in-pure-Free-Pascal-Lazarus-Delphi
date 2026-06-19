unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  Menus, Interfaces, PdfParser, PdfBitmapRenderer, XelPDF;

type

  { TForm1 }

  TForm1 = class(TForm)
    MainMenu1: TMainMenu;
    MenuItem1: TMenuItem;
    MenuItem11: TMenuItem;
    MenuItem12: TMenuItem;
    MenuItem13: TMenuItem;
    MenuItem14: TMenuItem;
    MenuItem15: TMenuItem;
    MenuItem16: TMenuItem;
    MenuItem17: TMenuItem;
    MenuItem18: TMenuItem;
    MenuItem19: TMenuItem;
    MenuItem7: TMenuItem;
    SelectDirectoryDialog1: TSelectDirectoryDialog;
    Separator3: TMenuItem;
    Separator2: TMenuItem;
    MenuItem2: TMenuItem;
    MenuItem3: TMenuItem;
    MenuItem4: TMenuItem;
    MenuItem5: TMenuItem;
    MenuItem6: TMenuItem;
    MenuItem8: TMenuItem;
    MenuItem9: TMenuItem;
    SaveDialog2: TSaveDialog;
    Separator1: TMenuItem;
    OpenDialog1: TOpenDialog;
    SaveDialog1: TSaveDialog;
    procedure Button1Click(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure MenuItem10Click(Sender: TObject);
    procedure MenuItem12Click(Sender: TObject);
    procedure MenuItem13Click(Sender: TObject);
    procedure MenuItem14Click(Sender: TObject);
    procedure MenuItem15Click(Sender: TObject);
    procedure MenuItem16Click(Sender: TObject);
    procedure MenuItem18Click(Sender: TObject);
    procedure MenuItem19Click(Sender: TObject);
    procedure MenuItem2Click(Sender: TObject);
    procedure MenuItem3Click(Sender: TObject);
    procedure MenuItem4Click(Sender: TObject);
    procedure MenuItem5Click(Sender: TObject);
    procedure MenuItem7Click(Sender: TObject);
    procedure MenuItem8Click(Sender: TObject);
  private

  public
    PDF: TXelPDF;
  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

{ TForm1 }

procedure TForm1.Button1Click(Sender: TObject);
begin
end;

procedure TForm1.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  Pdf.Free;
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  PDF := TXelPDF.Create(Form1);

  Pdf.Parent := Form1;
  Pdf.Align := alClient;
  PDf.AutoFit := afWidth;

  Pdf.LoadFromFile('2112.pdf');

end;

procedure TForm1.MenuItem10Click(Sender: TObject);
begin

end;

procedure TForm1.MenuItem12Click(Sender: TObject);
begin
  Pdf.Document.DrawRect(Pdf.CurrentPage, 20, 20, 200, 200, clRed);
end;

procedure TForm1.MenuItem13Click(Sender: TObject);
var Jpeg: TBytes;
begin
  //Pdf.Document.AddJpegImage(Pdf.CurrentPage, Jpeg, 20, 20, 200, 200);
end;

procedure TForm1.MenuItem14Click(Sender: TObject);
var FontRes: AnsiString;
begin
  FontRes := Pdf.Document.AddFont('Verdana', 40);
  Pdf.Document.AddText(Pdf.CurrentPage, 'Hello World', 20, 20, FontRes);
end;

procedure TForm1.MenuItem15Click(Sender: TObject);
begin
  Pdf.Document.RemovePage(Pdf.CurrentPage);
end;

procedure TForm1.MenuItem16Click(Sender: TObject);
begin
 Pdf.Document.AddPage(200,500);
end;

procedure TForm1.MenuItem18Click(Sender: TObject);
var i: Integer;
    Dir: String;
begin
  if not SelectDirectoryDialog1.Execute then Exit;
  Dir := ExtractFileDir(SelectDirectoryDialog1.FileName) + '\';

  for i:=0 to Pdf.Document.FontsCount-1 do
    Pdf.Document.ExportFont(i, Dir + IntToStr(i+1) + '.otf');
end;

procedure TForm1.MenuItem19Click(Sender: TObject);
begin
  Pdf.Document.RotateRight(Pdf.CurrentPage);
end;

procedure TForm1.MenuItem2Click(Sender: TObject);
begin
  if not OpenDialog1.Execute then Exit;
  Pdf.Document.LoadFromFile(OpenDialog1.Filename);
end;

procedure TForm1.MenuItem3Click(Sender: TObject);
begin
  if not SaveDialog1.Execute then Exit;
  Pdf.Document.SaveToFile(SaveDialog1.Filename);
end;

procedure TForm1.MenuItem4Click(Sender: TObject);
begin
  Close;
end;

procedure TForm1.MenuItem5Click(Sender: TObject);
begin
  if not SaveDialog2.Execute then Exit;
  Pdf.Document.ExtractTextToFile(0, SaveDialog2.Filename);
end;

procedure TForm1.MenuItem7Click(Sender: TObject);
begin
  Pdf.Document.RotateLeft(Pdf.CurrentPage);
end;

procedure TForm1.MenuItem8Click(Sender: TObject);
var TotalJpegs: Integer;
    i: Integer;
    Dir: String;
begin
  if not SelectDirectoryDialog1.Execute then Exit;
  Dir := ExtractFileDir(SelectDirectoryDialog1.FileName) + '\';

  TotalJpegs := Pdf.Document.JpegsCount(Pdf.CurrentPage);

  for i:=0 to TotalJpegs-1 do
    Pdf.Document.ExportJpeg(Pdf.CurrentPage, i, Dir + IntToStr(i+1) + '.jpg');

  for i:=0 to Pdf.Document.ImagesCount(Pdf.CurrentPage)-1 do
    Pdf.Document.ExportImage(Pdf.CurrentPage, i, Dir + IntToStr(i+TotalJpegs) + '.png');

end;

end.

