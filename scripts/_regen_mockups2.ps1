Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;

public static class MockupMaker3 {
  static GraphicsPath RoundedRect(float x,float y,float w,float h,float r){
    var p=new GraphicsPath(); float d=r*2;
    p.AddArc(x,y,d,d,180,90); p.AddArc(x+w-d,y,d,d,270,90); p.AddArc(x+w-d,y+h-d,d,d,0,90); p.AddArc(x,y+h-d,d,d,90,90); p.CloseFigure(); return p;
  }
  static void Bg(Graphics g,int mode){
    Color c1,c2; switch(mode){
      case 0: c1=Color.FromArgb(10,18,40); c2=Color.FromArgb(34,66,120); break;
      case 1: c1=Color.FromArgb(18,14,40); c2=Color.FromArgb(86,42,132); break;
      case 2: c1=Color.FromArgb(8,28,44); c2=Color.FromArgb(20,108,128); break;
      case 3: c1=Color.FromArgb(17,27,58); c2=Color.FromArgb(74,91,153); break;
      case 4: c1=Color.FromArgb(12,32,54); c2=Color.FromArgb(42,118,166); break;
      default: c1=Color.FromArgb(22,22,42); c2=Color.FromArgb(76,69,140); break;
    }
    using(var b=new LinearGradientBrush(new Rectangle(0,0,1024,500),c1,c2,35f)) g.FillRectangle(b,0,0,1024,500);
    var rng=new Random(1337+mode*17);
    for(int i=0;i<70;i++){ int x=rng.Next(1024), y=rng.Next(500), s=rng.Next(1,3), a=rng.Next(30,90); using(var sb=new SolidBrush(Color.FromArgb(a,255,255,255))) g.FillEllipse(sb,x,y,s,s); }
  }
  static void Card(Graphics g,string path,float x,float y,float w,float h,bool center,bool phone,string label){
    using(var sh=RoundedRect(x+6,y+8,w,h,22f)) using(var sb=new SolidBrush(Color.FromArgb(center?90:55,0,0,0))) g.FillPath(sb,sh);
    using(var fr=RoundedRect(x,y,w,h,22f)){ using(var fb=new SolidBrush(Color.FromArgb(19,28,49))) g.FillPath(fb,fr); using(var pen=new Pen(center?Color.FromArgb(245,228,176):Color.FromArgb(212,220,240),center?3f:2f)) g.DrawPath(pen,fr); }
    float m=phone?14f:12f, ix=x+m, iy=y+m, iw=w-2*m, ih=h-2*m;
    using(var inner=RoundedRect(ix,iy,iw,ih,12f)){
      using(var ib=new SolidBrush(Color.FromArgb(8,10,14))) g.FillPath(ib,inner);
      using(var img=Image.FromFile(path)){
        float scale=Math.Min(iw/img.Width, ih/img.Height); float dw=img.Width*scale, dh=img.Height*scale; float dx=ix+(iw-dw)/2f, dy=iy+(ih-dh)/2f;
        Region old=g.Clip; g.SetClip(inner); g.DrawImage(img,dx,dy,dw,dh); g.Clip=old;
      }
      using(var lb=new SolidBrush(Color.FromArgb(205,255,255,255))) using(var f=new Font("Segoe UI",center?10f:9f,FontStyle.Bold)) g.DrawString(label,f,lb,ix+8,iy+8);
    }
  }
  public static void Create(string outPath,string l,string c,string r,bool phone,int mode,string subtitle){
    using(var bmp=new Bitmap(1024,500)) using(var g=Graphics.FromImage(bmp)){
      g.SmoothingMode=SmoothingMode.AntiAlias; g.InterpolationMode=InterpolationMode.HighQualityBicubic; g.PixelOffsetMode=PixelOffsetMode.HighQuality; g.CompositingQuality=CompositingQuality.HighQuality;
      Bg(g,mode);
      if(phone){ Card(g,l,130,70,220,360,false,true,"Android"); Card(g,c,380,40,264,420,true,true,"Stellar Lens"); Card(g,r,674,70,220,360,false,true,"APOD"); }
      else { Card(g,l,56,132,290,210,false,false,"Desktop"); Card(g,c,344,100,336,252,true,false,"Stellar Lens"); Card(g,r,678,132,290,210,false,false,"Windows"); }
      using(var tb=new SolidBrush(Color.FromArgb(220,255,255,255))) using(var tf=new Font("Segoe UI",21f,FontStyle.Bold)) using(var sf=new Font("Segoe UI",10f,FontStyle.Regular)){ g.DrawString("Stellar Lens",tf,tb,28,24); g.DrawString(subtitle,sf,tb,30,58); }
      using(var ms=new MemoryStream()){
        bmp.Save(ms,System.Drawing.Imaging.ImageFormat.Png);
        File.WriteAllBytes(outPath, ms.ToArray());
      }
    }
  }
}
"@

$android=@('screenshots/android_SS/Screenshot_1777727594.png','screenshots/android_SS/Screenshot_1777731968.png','screenshots/android_SS/Screenshot_1777732004.png')
$windows=@('screenshots/windows_SS/Screenshot 2026-05-03 003100.png','screenshots/windows_SS/Screenshot 2026-05-03 003231.png','screenshots/windows_SS/Screenshot 2026-05-03 003308.png')

[MockupMaker3]::Create((Resolve-Path 'mockups/phone_mockup_01.png').Path,$android[1],$android[0],$android[2],$true,0,'Daily APOD • Carousel Preview')
[MockupMaker3]::Create((Resolve-Path 'mockups/phone_mockup_02.png').Path,$android[2],$android[1],$android[0],$true,1,'Immersive Mobile Space Feed')
[MockupMaker3]::Create((Resolve-Path 'mockups/phone_mockup_03.png').Path,$android[0],$android[2],$android[1],$true,2,'Explore NASA Photos Daily')
[MockupMaker3]::Create((Resolve-Path 'mockups/tablet_mockup_01.png').Path,$windows[1],$windows[0],$windows[2],$false,3,'Desktop Experience • Carousel Preview')
[MockupMaker3]::Create((Resolve-Path 'mockups/tablet_mockup_02.png').Path,$windows[2],$windows[1],$windows[0],$false,4,'Slideshow, Media, Wallpaper')
[MockupMaker3]::Create((Resolve-Path 'mockups/tablet_mockup_03.png').Path,$windows[0],$windows[2],$windows[1],$false,5,'Wide Layout APOD Browser')

Write-Host 'regen_done'
