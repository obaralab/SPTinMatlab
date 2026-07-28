
% CS reorienter

%This script performs a manual reorientation and classification of each CS
%in a reorganized CS structure. It needs to be open in the workspace and be
%titled "CS".

% If you want to include ER and mito channels as guides, you need to run
% this in a condition home directory so the raw images can be accessed. 

for i=118:size(CS,2)
    
   % Open DL images 
   imER=ChrisPrograms.loadtiff(fullfile(pwd, 'ER', strcat(CS(i).file,'_2_TA_BC.tif')));
   imMC=ChrisPrograms.loadtiff(fullfile(pwd, 'Mito', strcat(CS(i).file,'_3_TA_BC.tif')));
   
   % Remove frames that do not contribute tracks to the CS
   
   % Option 1: Trim the ends of the movie (leave frames with no steps that
   % are between frames with steps)
%    t1=min(CS(i).CSmatrix(:,:,1),[],'all','omitnan');
%    tn=max(CS(i).CSmatrix(:,:,1),[],'all','omitnan');
%    imER=imER(:,:,t1:tn);
%    imMC=imMC(:,:,t1:tn);
   
   % Option 2: Remove all frames that do not have at least one
   % CS-associated localization with them
   tset=unique(CS(i).CSmatrix(:,:,1))+1;
   tset=tset(isfinite(tset));
   imER=imER(:,:,tset);
   imMC=imMC(:,:,tset);
   
   % Define the projection image and scale the colors
   imDL(:,:,1)=sum(imER,3,'omitnan');
   imDL(:,:,2)=sum(imMC,3,'omitnan');
   imRGB=imfuse(imDL(:,:,2),imDL(:,:,1),'ColorChannels','red-cyan');
   
   % Find the region of the image that matters
   imDisp=zeros(25,25,3);
   
   PixCenter=round(6.25*CS(i).refCenter);
   Bounds=[PixCenter-12; PixCenter+12];
   
   Edge=(Bounds<=0)+(Bounds>=128);
   if sum(Edge,'all')>=3
       error('Somehow you are hanging > 3 edges of the image at once?');
   end
   
   if sum(Edge,'all')==0
       imER=imER(Bounds(1,1):Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
       imMC=imMC(Bounds(1,1):Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
       imDL=imDL(Bounds(1,1):Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
       imDisp(:,:,:)=imRGB(Bounds(1,1):Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
   else
       if Edge(1,1)==1
           %Left side hangs off
           if Edge(1,2)==1
               %Top also off
                imER=imER(1:Bounds(2,1),1:Bounds(2,2),:);
                imMC=imMC(1:Bounds(2,1),1:Bounds(2,2),:);
                imDL=imDL(1:Bounds(2,1),1:Bounds(2,2),:);
                imDisp((-1*Bounds(1,1)+2):25,(-1*Bounds(1,2)+2):25,:)=imRGB(1:Bounds(2,1),1:Bounds(2,2),:);
                
           elseif Edge(2,2)==1
               %Bottom also off
                imER=imER(1:Bounds(2,1),Bounds(1,2):128,:);
                imMC=imMC(1:Bounds(2,1),Bounds(1,2):128,:);
                imDL=imDL(1:Bounds(2,1),Bounds(1,2):128,:);
                imDisp((-1*Bounds(1,1)+2):25,1:(25-(Bounds(2,2)-128)),:)=imRGB(1:Bounds(2,1),Bounds(1,2):128,:);
                
           else
               %Left side only
                imER=imER(1:Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
                imMC=imMC(1:Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
                imDL=imDL(1:Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
                imDisp((-1*Bounds(1,1)+2):25,:,:)=imRGB(1:Bounds(2,1),Bounds(1,2):Bounds(2,2),:);
               
           end
       elseif Edge(2,1)==1
           %Right side hangs off
           if Edge(1,2)==1
               %Top also off
                imER=imER(Bounds(1,1):128,1:Bounds(2,2),:);
                imMC=imMC(Bounds(1,1):128,1:Bounds(2,2),:);
                imDL=imDL(Bounds(1,1):128,1:Bounds(2,2),:);
                imDisp(1:(25-(Bounds(2,1)-128)),(-1*Bounds(1,2)+2):25,:)=imRGB(Bounds(1,1):128,1:Bounds(2,2),:);
           elseif Edge(2,2)==1
               %Bottom also off
                imER=imER(Bounds(1,1):128,Bounds(1,2):128,:);
                imMC=imMC(Bounds(1,1):128,Bounds(1,2):128,:);
                imDL=imDL(Bounds(1,1):128,Bounds(1,2):128,:);
                imDisp(1:(25-(Bounds(2,1)-128)),1:(25-(Bounds(2,2)-128)),:)=imRGB(Bounds(1,1):128,Bounds(1,2):128,:);
           else
               %Nope just the right side
                imER=imER(Bounds(1,1):128,Bounds(1,2):Bounds(2,2),:);
                imMC=imMC(Bounds(1,1):128,Bounds(1,2):Bounds(2,2),:);
                imDL=imDL(Bounds(1,1):128,Bounds(1,2):Bounds(2,2),:);
                imDisp(1:(25-(Bounds(2,1)-128)),:,:)=imRGB(Bounds(1,1):128,Bounds(1,2):Bounds(2,2),:);
           end
       elseif Edge(1,2)==1
           % Top hangs off only
            imER=imER(Bounds(1,1):Bounds(2,1),1:Bounds(2,2),:);
            imMC=imMC(Bounds(1,1):Bounds(2,1),1:Bounds(2,2),:);
            imDL=imDL(Bounds(1,1):Bounds(2,1),1:Bounds(2,2),:);
            imDisp(:,(-1*Bounds(1,2)+2):25,:)=imRGB(Bounds(1,1):Bounds(2,1),1:Bounds(2,2),:);
       elseif Edge(2,2)==1
           %Bottom hangs off only
            imER=imER(Bounds(1,1):Bounds(2,1),Bounds(1,2):128,:);
            imMC=imMC(Bounds(1,1):Bounds(2,1),Bounds(1,2):128,:);
            imDL=imDL(Bounds(1,1):Bounds(2,1),Bounds(1,2):128,:);
            imDisp(:,1:(25-(Bounds(2,2)-128)),:)=imRGB(Bounds(1,1):Bounds(2,1),Bounds(1,2):128,:);
       else
           error('Something has gone wrong--no edge found?');
       end
           
   end
  
   % Make the figure for tracing
   fig1=figure(1);
   set(fig1, 'WindowState', 'maximized');
   subplot(1,2,2);
   imshow(uint8(imresize(imDisp,12)),'Border','tight');
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
    CS(i).DLimage.imER=imER;
    CS(i).DLimage.imMC=imMC;
    CS(i).DLimage.imDL=imDL;
    
    % Save alignment and classification information
    CS(i).Orientation.North=North;
    CS(i).NumExits=NumExits;
    CS(i).IDs.t_set=tset;
    
    close(fig1);
    clear('imDL');
    
end