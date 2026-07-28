
function plotEllipseFit(CSstruct,index,origin)

if nargin==2
    origin=[0 0];
end

if nargin==1
    origin=[0 0];
    index=1;
end

    
    a=CSstruct(index).EllipseFit.MajorAxisLength/2;
    b=CSstruct(index).EllipseFit.MinorAxisLength/2;
    c=CSstruct(index).EllipseFit.Centroid-origin;
    d=linspace(0,2*pi,100);
    phi=-CSstruct(index).EllipseFit.Orientation;
    % Note ellipses are centered at zero, zero in this form (if you want to
    % change that add an h +k factor to lines 56 + 57, respectively
    x=c(1)+a*cos(d)*cosd(phi)-b*sin(d)*sind(phi);
    y=c(2)+a*cos(d)*sind(phi)+b*sin(d)*cosd(phi);
    plot(x,y,'r','LineWidth',1.5);
    hold on
    MajAx=[x(1), y(1); x(50), y(50)];
    MinAx=[x(25), y(25); x(75), y(75)];
    plot(MajAx(:,1),MajAx(:,2), 'b', 'LineWidth',1.5);
    plot(MinAx(:,1),MinAx(:,2), 'b', 'LineWidth',1.5);
    
end