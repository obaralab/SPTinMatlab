
% Code for generating searchble list of contact sites and files for
% plotting impotant aspects of any example.

%To run this, you just need to open the variable "CS" and be in the
%condition home directory.

%Make folders to hold output data
mkdir CS_turbo
mkdir CS_jet
mkdir VectorGraphics
mkdir DeffVisual
mkdir TracksVisual

%Allocate memory for processing
Col1=NaN(size(CS,2),1);
Col2=NaN(size(CS,2),1);
Col3=NaN(size(CS,2),1);
Col4=NaN(size(CS,2),1);
Col5=NaN(size(CS,2),1);
Col6=NaN(size(CS,2),1);
Col7=NaN(size(CS,2),1);
Col8=NaN(size(CS,2),1);
Col9=NaN(size(CS,2),1);
Col10=NaN(size(CS,2),1);
Col11=NaN(size(CS,2),1);
Col12=NaN(size(CS,2),1);
Col13=NaN(size(CS,2),1);
Col14=NaN(size(CS,2),1);
Col15=NaN(size(CS,2),1);

for i=1:size(CS,2)
    
    Col1(i)=i;
    Col2(i)=CS(i).cellIndex;
    Col3(i)=CS(i).csID;
    Col4(i)=size(CS(i).tracks,2);
    Col5(i)=nnz(isfinite(CS(i).tracksCCids));
    Col6(i)=size(unique(nonzeros(CS(i).segIDs(isfinite(CS(i).segIDs)))),1);
    Col7(i)=CS(i).EllipseFit.MajorAxisLength;
    Col8(i)=CS(i).EllipseFit.MinorAxisLength;
    Col9(i)=CS(i).EllipseFit.Orientation;
    Col10(i)=sum(CS(i).ChPts.*logical(CS(i).IDmatrixCSspec),'all','omitnan');
%     Col11(i)=mean(CS(i).refDeff,'omitnan');
%     Col12(i)=size(CS(i).refDeff,1);
%     Col13(i)=mean(CS(i).neighborDeff,'omitnan');
%     Col14(i)=size(CS(i).neighborDeff,1);
    Col15(i)=CS(i).MitoFlag;
    
    % Change the last input if you want bigger regions (currently set to
    % 1.2 um neighborhoods for visualization (1.024 for analysis))
    imG=LocDensityFigGenerate(CS(i).CSmatrix(:,:,2),CS(i).CSmatrix(:,:,3),30,[-20 20]);
    
    % Save density plots
    fig1=figure(1);
    hold off
    imshow(imG,turbo,'Border','tight');
    fig1.Position=[300 300 768 768];
    saveas(fig1,fullfile(pwd, 'CS_turbo', strcat('CS_',num2str(i),'_turbo.png')));
    
    imshow(imG,jet,'Border','tight');
    fig1.Position=[300 300 768 768];
    saveas(fig1,fullfile(pwd, 'CS_jet', strcat('CS_',num2str(i),'_jet.png')));
    
    % Save vector graphics
        uM_SF=333.333;
        pix_SF=10;
        uM_off=200;
        pix_off=200;
        
    % Tracks
    ColorMatrix=[0 0.4470 0.7410; 0.8500 0.3250 0.0980;0.9290 0.6940 0.1250;0.4940 0.1840 0.5560;0.4660 0.6740 0.1880;0.3010 0.7450 0.9330];
    imshow(255*ones(400,400,3),'Border','tight');
    hold on
    fig1.Position=[300 300 768 768];
    colororder(ColorMatrix);
    plot(uM_SF*CS(i).CSmatrix(:,:,2)+uM_off,uM_SF*(CS(i).CSmatrix(:,:,3))+uM_off);
    saveas(fig1,fullfile(pwd, 'VectorGraphics', strcat('CS_',num2str(i),'_tracks.svg')));
    
    % Vectors
    hold off
    imshow(255*ones(400,400,3),'Border','tight');
    hold on
    fig1.Position=[300 300 768 768];
    for j=1:size(CS(i).tracks,2)
        quiver(uM_SF*CS(i).CSmatrix(1:end-1,j,2)+uM_off,uM_SF*(CS(i).CSmatrix(1:end-1,j,3))+uM_off,CS(i).CSvec(:,j,1),CS(i).CSvec(:,j,2));
    end
    saveas(fig1,fullfile(pwd, 'VectorGraphics', strcat('CS_',num2str(i),'_vector.svg')));
    
    % Deff Scatter
%     hold off
%     imshow(255*ones(400,400,3),'Border','tight');
%     hold on
%     fig1.Position=[300 300 768 768];
%     A=CS(i).CSmatrix(:,:,2);
%     B=CS(i).CSmatrix(:,:,3);
%     C=CS(i).Deff;
%     colormap(flipud(jet));
%     scatter(uM_SF*A(:)+uM_off,uM_SF*B(:)+uM_off,[],C(:),'filled');
%     colorbar;
%     saveas(fig1,fullfile(pwd, 'VectorGraphics', strcat('CS_',num2str(i),'_DeffScatter.svg')));
    
    % NPB Tracks
    hold off
    imshow(255*ones(400,400,3),'Border','tight');
    hold on
    fig1.Position=[300 300 768 768];
    plot(uM_SF*(CS(i).CSmatrix(:,:,2).*isfinite(CS(i).tracksCCids))+uM_off,uM_SF*(CS(i).CSmatrix(:,:,3)).*isfinite(CS(i).tracksCCids)+uM_off,'r')
    saveas(fig1,fullfile(pwd, 'VectorGraphics', strcat('CS_',num2str(i),'_NPBtracks.svg')));
    
    % Boundary
    hold off
    imshow(255*ones(400,400,3),'Border','tight');
    hold on
    fig1.Position=[300 300 768 768];
    smBound=[CS(i).refboundary(end-4:end,:); CS(i).refboundary; CS(i).refboundary(1:4,:)];
    smBound=smoothdata(smBound,1,'movmean',5);
    plot(smBound(:,1)/3+uM_off,smBound(:,2)/3+uM_off);
    saveas(fig1,fullfile(pwd, 'VectorGraphics', strcat('CS_',num2str(i),'_Boundary.svg')));
    
    % Ellipse Fit
    hold off
    imshow(255*ones(400,400,3),'Border','tight');
    hold on
    fig1.Position=[300 300 768 768];
    a=CS(i).EllipseFit.MajorAxisLength/2;
    b=CS(i).EllipseFit.MinorAxisLength/2;
    c=CS(i).EllipseFit.Centroid;
    d=linspace(0,2*pi,100);
    phi=-CS(i).EllipseFit.Orientation;
    % Note ellipses were calculated for a center of 31,31
    x=c(1)+a*cos(d)*cosd(phi)-b*sin(d)*sind(phi)-31;
    y=c(2)+a*cos(d)*sind(phi)+b*sin(d)*cosd(phi)-31;
    plot(pix_SF*x+pix_off,pix_SF*y+pix_off,'r','LineWidth',1.5);
    MajAx=[x(1), y(1); x(50), y(50)];
    MinAx=[x(25), y(25); x(75), y(75)];
    plot(pix_SF*MajAx(:,1)+pix_off,pix_SF*MajAx(:,2)+pix_off, 'b', 'LineWidth',1.5);
    plot(pix_SF*MinAx(:,1)+pix_off,pix_SF*MinAx(:,2)+pix_off, 'b', 'LineWidth',1.5);
    saveas(fig1,fullfile(pwd, 'VectorGraphics', strcat('CS_',num2str(i),'_EllipseFit.svg')));
    
    
    % Generate Overlays for visualization aids
     hold off
    imshow(255*ones(400,400,3),'Border','tight');
    hold on
    fig1.Position=[300 300 768 768];
    plot(uM_SF*CS(i).CSmatrix(:,:,2)+uM_off,uM_SF*(CS(i).CSmatrix(:,:,3))+uM_off,'b','Linewidth',1);
    plot(pix_SF*x+pix_off,pix_SF*y+pix_off,'k','LineWidth',1.5);
    plot(pix_SF*MajAx(:,1)+pix_off,pix_SF*MajAx(:,2)+pix_off, 'k', 'LineWidth',1.5);
    plot(pix_SF*MinAx(:,1)+pix_off,pix_SF*MinAx(:,2)+pix_off, 'k', 'LineWidth',1.5);
    saveas(fig1,fullfile(pwd, 'DeffVisual', strcat('CS_',num2str(i),'_DeffVis.png'))); 
    
    hold off
    imshow(255*ones(400,400,3),'Border','tight');
    hold on
    fig1.Position=[300 300 768 768];
    plot(uM_SF*CS(i).CSmatrix(:,:,2)+uM_off,uM_SF*(CS(i).CSmatrix(:,:,3))+uM_off,'b','Linewidth',1);
    plot(uM_SF*(CS(i).CSmatrix(:,:,2).*isfinite(CS(i).tracksCCids))+uM_off,uM_SF*(CS(i).CSmatrix(:,:,3)).*isfinite(CS(i).tracksCCids)+uM_off,'r','Linewidth',1.0);
    plot(smBound(:,1)/3+uM_off,smBound(:,2)/3+uM_off,'y','LineWidth',1.5);
    saveas(fig1,fullfile(pwd, 'TracksVisual', strcat('CS_',num2str(i),'_TracksVis.png'))); 
    
    
end

T=table(Col1,Col2,Col3,Col4,Col5,Col6,Col7,Col8,Col9,Col10,Col11,Col12,Col13,Col14,Col15);
T=renamevars(T,{'Col1','Col2','Col3','Col4','Col5','Col6','Col7','Col8','Col9','Col10','Col11','Col12','Col13','Col14','Col15'},{'CS #','Cell Index','csID','# tracks','# NPB tracks','# segIDs','MajorAx','MinorAx','Angle','#ChPts','MeanDeff','n','NeighborhoodDeff','n neighborhood','MitoFlag'});

writetable(T,'CS_details.xlsx');


