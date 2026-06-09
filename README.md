# Usage examples

## Just showing a PDF:
```
type
  TForm1 = class(TForm)
...
  public
    PDF: TXelPDF;
  end;
...
procedure TForm1.FormCreate(Sender: TObject);
begin
  PDF := TXelPDF.Create(Form1);
  Pdf.Parent := Form1;
  Pdf.Align := alClient;
  Pdf.LoadFromFile('test.pdf');
end;

procedure TForm1.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  Pdf.Free;
end;  
```

## Converting .TXT to .PDF
```
PDF := TXelPDF.Create(Form1);
Pdf.LoadFromFile('input.txt');
Pdf.Document.SaveToFile('txt.pdf');
```

## Exporting an embedded font:
``
TotalFonts := PDF.Document.CountFonts; //count fonts in the PDF
PDF.Document.ExportFont(5, 'out.otf'); //5 is the number of the font
```

## Exporting a JPEG or another bitmap:
```
//images that are embedded as JPEGs in the PDF- no recompression, except CMYK->RGB
Total := Doc.JpegsCount(PageNumber);
Doc.ExportJpeg(PageNumber, JpegNumber, 'out.jpg');
```
Other images:
```
//images that are embedded in other formats in the PDF- conversion to PNG
Total := Doc.ImagesCount(PageNumber);
Doc.ExportImage(PageNumber, ImageNumber, 'out.png');
```
