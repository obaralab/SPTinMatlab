
% CS reorienter

%This script performs a manual reorientation and classification of each CS
%in a reorganized CS structure. It needs to be open in the workspace and be
%titled "CS".

% If you want to include ER and mito channels as guides, you need to run
% this in a condition home directory so the raw images can be accessed. 

% This version scales the DL image to the local region, not globally. Use
% v2 for a global scaling approach.

for i=1:size(CS,2)
    
   % Open DL images 
   imER=ChrisPrograms.loadtiff(fullfile(pwd, 'ER', strcat(CS(i).file,'_2_8bit.tif')));
   imMC=ChrisPrograms.loadtiff(fullfile(pwd, 'Mito', strcat(CS(i).file,'_3_maxS2N_8bit.tif')));
   
   % Remove frames that do not contribute tracks to the CS
   
   % Option 1: Trim the ends of the movie (leave frames with no steps that
   % are between frames with steps)
%    t1=min(CS(i).CSmatrix(:,:,1),[],'all','omitnan');
%    tn=max(CS(i).CSmatrix(:,:,1),[],'all','omitnan');
%    imER=imER(:,:,t1:tn);
%    imMC=imMC(:,:,t1:tn);
   
   % Option 2: Remove all frames that do not have at least one
   % CS-associated localization with them
   tset=unique(CS(i).CSmatrix(:,:,1));
   tset=tset(isfinite(tset));
   imER=imER(:,:,tset);
   imMC=imMC(:,:,tset);
   
   % Find the region of the image that matters
   imDisp=zeros(25,25,2);
   
   PixCenter=round((1/cs_config().DL_PixSize_um)*CS(i).refCenter); % per-camera struct-image px/um (was 6.25)
   Bounds=[PixCenter-12; PixCenter+12];
   
   Edge=(Bounds<=0)+(Bounds>=128);
   if sum(Edge,'all')>=3
       error('Somehow you are hanging > 3 edges of the image at once?');
   end
   
   if sum(Edge,'all')==0
       imER=imER(Bounds(1,1):Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
       imMC=imMC(Bounds(1,1):Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
       imDisp(:,:,1)=sum(imER,3,'omitnan');
       imDisp(:,:,2)=sum(imMC,3,'omitnan');
   else
       if Edge(1,1)==1
           %Left side hangs off
           if Edge(1,2)==1
               %Top also off
                imER=imER(1:Bounds(2,1),1:Bounds(2,2),:);
                imMC=imMC(1:Bounds(2,1),1:Bounds(2,2),:);
                imDisp((-1*Bounds(1,1)+2):25,(-1*Bounds(1,2)+2):25,1)=sum(imER,3,'omitnan');
                imDisp((-1*Bounds(1,1)+2):25,(-1*Bounds(1,2)+2):25,2)=sum(imMC,3,'omitnan');
           elseif Edge(2,2)==1
               %Bottom also off
                imER=imER(1:Bounds(2,1),Bounds(1,2):128,:);
                imMC=imMC(1:Bounds(2,1),Bounds(1,2):128,:);
                imDisp((-1*Bounds(1,1)+2):25,1:(25-(Bounds(2,2)-128)),1)=sum(imER,3,'omitnan');
                imDisp((-1*Bounds(1,1)+2):25,1:(25-(Bounds(2,2)-128)),2)=sum(imMC,3,'omitnan');
           else
               %Left side only
                imER=imER(1:Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
                imMC=imMC(1:Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
                imDisp((-1*Bounds(1,1)+2):25,:,1)=sum(imER,3,'omitnan');
                imDisp((-1*Bounds(1,1)+2):25,:,2)=sum(imMC,3,'omitnan');
           end
       elseif Edge(2,1)==1
           %Right side hangs off
           if Edge(1,2)==1
               %Top also off
                imER=imER(Bounds(1,1):128,1:Bounds(2,2),:);
                imMC=imMC(Bounds(1,1):128,1:Bounds(2,2),:);
                imDisp(1:(25-(Bounds(2,1)-128)),(-1*Bounds(1,2)+2):25,1)=sum(imER,3,'omitnan');
                imDisp(1:(25-(Bounds(2,1)-128)),(-1*Bounds(1,2)+2):25,2)=sum(imMC,3,'omitnan');
           elseif Edge(2,2)==1
               %Bottom also off
                imER=imER(Bounds(1,1):128,Bounds(1,2):128,:);
                imMC=imMC(Bounds(1,1):128,Bounds(1,2):128,:);
                imDisp(1:(25-(Bounds(2,1)-128)),1:(25-(Bounds(2,2)-128)),1)=sum(imER,3,'omitnan');
                imDisp(1:(25-(Bounds(2,1)-128)),1:(25-(Bounds(2,2)-128)),2)=sum(imMC,3,'omitnan');
           else
               %Nope just the right side
                imER=imER(Bounds(1,1):128,Bounds(1,2):Bounds(2,2),:);
                imMC=imMC(Bounds(1,1):128,Bounds(1,2):Bounds(2,2),:);
                imDisp(1:(25-(Bounds(2,1)-128)),:,1)=sum(imER,3,'omitnan');
                imDisp(1:(25-(Bounds(2,1)-128)),:,2)=sum(imMC,3,'omitnan');
           end
       elseif Edge(1,2)==1
           % Top hangs off only
            imER=imER(Bounds(1,1):Bounds(2,1),1:Bounds(2,2),:);
            imMC=imMC(Bounds(1,1):Bounds(2,1),1:Bounds(2,2),:);
            imDisp(:,(-1*Bounds(1,2)+2):25,1)=sum(imER,3,'omitnan');
            imDisp(:,(-1*Bounds(1,2)+2):25,2)=sum(imMC,3,'omitnan');
       elseif Edge(2,2)==1
           %Bottom hangs off only
            imER=imER(Bounds(1,1):Bounds(2,1),Bounds(1,2):128,:);
            imMC=imMC(Bounds(1,1):Bounds(2,1),Bounds(1,2):128,:);
            imDisp(:,1:(25-(Bounds(2,2)-128)),1)=sum(imER,3,'omitnan');
            imDisp(:,1:(25-(Bounds(2,2)-128)),2)=sum(imMC,3,'omitnan');
       else
           error('Something has gone wrong--no edge found?');
       end
           
   end
   
   % Make the 2 channel image
   imDL=imfuse(imDisp(:,:,1),imDisp(:,:,2),'ColorChannels','red-cyan');

   % Make the figure for tracing
   fig1=figure(1);
   set(fig1, 'WindowState', 'maximized');
   subplot(1,2,2);
   imshow(imresize(imDL,12),'Border','tight');
   hold on
   plot([105 195 195 105 105],[105 105 195 195 105],'y','LineWidth',1.5);
   scatter(150,150,[],'k');
   
   subplot(1,2,1);
   imG=LocDensityFigGenerate(CS(i).CSmatrix(:,:,2),CS(i).CSmatrix(:,:,3),30,[-20 20]);
   imG=imresize(imG,10);
   imshow(imG,turbo,'Border','tight');
   hold on
   scatter(200,200,[],'k');
   plot(333.333*CS(i).boundaries.refBoundary(:,1)+200,333.333*CS(i).boundaries.refBoundary(:,2)+200,'k');
   
   % Define the desired "True North"
   roi=drawpoint;
   North=roi.Position;
   
   % Interact with user
   Class=inputdlg({'Desired Classification:'},'Contact Site Type');
   NumExits=str2num(Class{1});

    % Save Images to CS structure
    CS(i).imER=imER;
    CS(i).imMC=imMC;
    CS(i).imDL=imDL;
    
    % Save alignment and classification information
    CS(i).North=North;
    CS(i).NumExits=NumExits;
    
    close(fig1);
    
end