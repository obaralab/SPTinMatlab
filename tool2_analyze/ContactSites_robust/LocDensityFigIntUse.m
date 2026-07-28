% Plot Step Density

function [imG,Hraw]=LocDensityFigIntUse(TrackStruct,index,PixSize)


close all

cfg=cs_config(); Bins=PixSize*(1:ceil(cfg.FOV_um/(PixSize/1000))+1);

fig1=figure('Visible','off');   % off-screen: this QC render must not flash during a run

Hraw=histogram2(1000*TrackStruct(index).matrix(:,:,2),1000*TrackStruct(index).matrix(:,:,3),Bins,Bins,'DisplayStyle','tile');
set(fig1,'Position',[100 300 768 768]);
% ROBUST FIX (orientation): histogram2 'tile' draws Cartesian (Y up), but the
% density map in fig3 (imshow, Y down), the saved Density_*.tif, and the raw
% mito/ER TIFFs are all image-convention (Y down). Reverse this axis so the
% localization figure matches them. Display-only; the saved data is untouched.
set(gca,'YDir','reverse');
%LocDensity=Hraw;


imG=30*imgaussfilt(Hraw.Values,[2 2]);
imG=imG';
fig3=figure('Visible','off');
imshow(uint8(imG), jet, 'Border','tight');
fig3.Position=[800 300 768 768];
Total=TrackStruct(index).matrix(:,:,2);
Total(~isfinite(Total))=0;
NormTotal=sum(sum(logical(Total)));
disp(strcat('Total Localizations is :',num2str(NormTotal)));
disp(strcat('Axis max is :',num2str((255/30)/NormTotal,2)));

%close(fig1);

%saveas(fig3, strcat('Cell_', num2str(index), '_Densities.jpg'));
%ChrisPrograms.saveastiff(imG,fullfile(pwd, strcat('Cell_', num2str(index), '_Densities.tif')));

%imS=double(imS);
%NormFactor=sum(sum(imS,1),2);
%imSnorm=bsxfun(@rdivide,imS,NormFactor);

%PixLoc=ceil(6.25*TrackStruct(index).matrix(:,:,2:3))+1;
%PixLoc(:,:,1)=PixLoc(:,:,1)+x;
%PixLoc(:,:,2)=PixLoc(:,:,2)+y;

%PixLoc(PixLoc==0)=1;
%LinIndex=sub2ind(size(imS),PixLoc(:,:,1),PixLoc(:,:,2),TrackStruct(index).matrix(:,:,1)+1);
%ProbCoeff=zeros(size(LinIndex));

%for i=1:size(TrackStruct(index).matrix,2)
    
%    ProbCoeff(1:TrackStruct(index).lengths(i),i)=imSnorm(LinIndex(1:TrackStruct(index).lengths(i),i));
    
%end
    
%[~,~,~,binX,binY]=histcounts2(1000*TrackStruct(index).matrix(:,:,2),1000*TrackStruct(index).matrix(:,:,3),Bins,Bins);

%Hnorm=zeros(Hraw.NumBins);

%for i=1:size(ProbCoeff,2)
    
 %   for j=1:TrackStruct(index).lengths(i)
        
   %     Hnorm(binX(j,i)+1,binY(j,i)+1)=Hnorm(binX(j,i)+1,binY(j,i)+1)+1/ProbCoeff(j,i);
        
  %  end
       
%end

%DensityMatrix=struct('X',TrackStruct(index).matrix(:,:,2),'Y',TrackStruct(index).matrix(:,:,3),'t',TrackStruct(index).matrix(:,:,1))%,'ProbCoeff',ProbCoeff,'imS',imS,'imSnorm',imSnorm,'Hnorm',Hnorm);

save(strcat('Density_',TrackStruct(index).file,'.mat'),'imG');
%save('DensityMatrix','DensityMatrix','-v7.3');
ChrisPrograms.saveastiff(uint16(imG),strcat('Density_',TrackStruct(index).file,'.tif'));

% The density data is now saved; close the QC display windows so they do
% not pile up as popups across the per-cell loop. The .mat/.tif on disk
% remain available for panel display.
for h = [fig1 fig3]
    if isgraphics(h), close(h); end
end
%fig2=figure(2);
%imN=imgaussfilt(Hnorm,[2 2]);
%imshow(uint16(imN/550), jet);
%fig2.Position=[900 400 768 768];

%close(fig3);

end

