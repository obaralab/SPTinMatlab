
function CS_refiner_v2_wacom(TrackStruct,MitoFlag,inputDir,outputDir)

%CS refiner

% Version 2023: 
% Runs as function, designed for legacy purposes to run in home directory of condition after
% ContactSiteMapper, but can force to other directory for CS inputs ('*_CSdata.mat') by
% setting inputDir.

% Will save each cell's data in an outputfolder, CSdata by default unless
% specified otherwise in outputDir.

%MitoFlag behavior: 0 (default) ignore mitoFlag, 1 - use MitoFlag to parse,
% -1 - use MitoFlag to avoid.

close all

if nargin==1
    % Legacy CSrefiner2.m
    MitoFlag=0;
    inputDir=fullfile(pwd,'TrackData');
    outputDir=fullfile(pwd, 'CSdata');
elseif nargin==2
    % Legacy CSrefiner1.m or CSrefiner3.m
    inputDir=fullfile(pwd,'TrackData');
    outputDir=fullfile(pwd, 'CSdata');
elseif nargin==3
    % Chooose data somewhere else and just vomit it where I am?
    outputDir=fullfile(pwd, 'CSdata');
end

% Some things that should only very rarely need changed:
    PixSize=30; % in nm, change only if you know you changed this
    ROI=[-40 40]; % +/- Dimensions analyzed in pixels (+/- 20 is 40 pix=1.2 um)
    AmpFactor=10; % How big to scale the image for user resolution
    % Change the ROI input if you want bigger regions (currently set to
    % 1.2 um neighborhoods for visualization (1.024 for analysis))--BUT DO
    % NOT FORGET TO UPDATE WHICH TRACKS ARE ASSOCIATED TO MATCH OR THIS
    % WILL MISS DATA FROM THE RESULTING CSdata structures
    SF=(1/AmpFactor)*(PixSize/1000); %Converts scaled pix to microns


% Find the output files from ContactSiteMapper.m
Files=dir(fullfile(inputDir,'*_CSdata.mat'));
files={Files.name}';
mkdir(outputDir);

%Loop through each cell and refine center
for i=1:size(Files,1)
   filename=char(files(i)); 
   load(fullfile(inputDir,filename),'CSdata');
   
   % Obey the MitoFlag rule
   MitoFlagList=NaN(size(CSdata));
   for k=1:size(CSdata,2)
       MitoFlagList(k)=CSdata(k).MitoFlag;
   end

   if MitoFlag==1
       listCSs=find(MitoFlagList);
   elseif MitoFlag==-1
       listCSs=find(~MitoFlagList);
   elseif MitoFlag==0
       listCSs=1:size(CSdata,2);
   else
       error('Your MitoFlag instructions are not in the correct format.');
   end

   %Loop through each intended CS and refine the center
   
   for j=1:size(listCSs,2)

       % Generate references in case you need to check anything
        X=TrackStruct(i).matrix(:,CSdata(listCSs(j)).Tracks,2)-CSdata(listCSs(j)).center(1);
        Y=TrackStruct(i).matrix(:,CSdata(listCSs(j)).Tracks,3)-CSdata(listCSs(j)).center(2);
        %Prob don't need this unless you start t-filtering, but if so change it here:
        T=TrackStruct(i).matrix(:,CSdata(listCSs(j)).Tracks,1);

           % XY plot
            figure;
            plot(X,Y);
            xlim([-1.5 1.5]);
            ylim([-1.5 1.5]);
            axis square
            set(gca,'Ydir','reverse')
            title(['Cell ID=', num2str(i),' CS number=', num2str(listCSs(j))]);

           % RT plot
            figure;
            plot(0.011*T,sqrt(X.^2+Y.^2),'LineWidth',1.5);
            ylim([-0.5 3.5]);
            %xlim([0 2500]);
            hold on
            yline(0,'--');
            set(gcf,'Position',[50 250 2400 400]);
            xlabel('Time (sec)');
            ylabel('Distance from CS Center (\mum)');
            set(gca,'FontSize',20);
       
       % Make a map of the cell so you can ID other CSs
            Label_CS_DensityPlot_intUse(TrackStruct(i),CSdata,listCSs(j));
            set(gcf, "Position", [100 800 700 700]);

       % Make a cute little CS to look at
       imG=LocDensityFigGenerate(X,Y,PixSize,ROI);
            figure;
            hold off
            imG=imresize(imG,AmpFactor);
            imG=flip(imG,1);
            imshow(imG,turbo,'Border','tight');
            set(gcf,'Position',[500 -650 500 500]);
       
       roi1=drawpoint;
       
       % Save the refined center
        % Note that ROI gives upper and lower bounds for an obligate square
        % (measured from the center of the putative CS)
        % in this format, so the X and Y offsets are always +the minor
        % limit, which is negative since it is measured against the center.
        % You'll need to change this if you start dealing in rectangles.
       CSdata(listCSs(j)).refCenter=[(SF*(roi1.Position(1)+AmpFactor*ROI(1)))+CSdata(listCSs(j)).center(1)...
           (SF*(roi1.Position(2)+AmpFactor*ROI(1)))+CSdata(listCSs(j)).center(2)];
   
       % Now ask for the boundary
       hold on
       scatter(roi1.Position(1),roi1.Position(2),[],'k','filled');

       roi2=drawfreehand;
       %record the boundary in units of nm centered on CS (and add a
       %correction term for the difference between the refCenter and the
       %original one, or it will be off, since the pixel image is centered
       %at the original center.
            Xboundry=1000*SF*(roi2.Position(:,1)+AmpFactor*ROI(1)); % X coordinates of boundary in centered on CSdata(*).center(1)
            Xdisp=1000*(CSdata(listCSs(j)).refCenter(1)-CSdata(listCSs(j)).center(1)); %nm vector that pushes Xcenter to refCenter
            Yboundary=1000*SF*(roi2.Position(:,2)+AmpFactor*ROI(1)); % Y coordinates of boundary in centered on CSdata(*).center(2)
            Ydisp=1000*(CSdata(listCSs(j)).refCenter(2)-CSdata(listCSs(j)).center(2)); % nm vector to push Ycenter to refCenter
       CSdata(listCSs(j)).refboundary=[Xboundry-Xdisp, Yboundary-Ydisp];
   
       %remove NaN's so inROI command can work (Note ROI cannot include
       %top left corner or these will create artifacts)
            % In case i don't remember later, these do NOT need scaled by
            % Xdisp and Ydisp because the data is already scaled by Center
            % when its placed on the graph and ROI2 doesn't use refCenter
            % to orient itself.
       Aprime=X-SF*AmpFactor*ROI(1);
       Aprime(~isfinite(Aprime))=0;
       Bprime=Y-SF*AmpFactor*ROI(1);
       Bprime(~isfinite(Bprime))=0;

       %generate an identity matrix in CS m and n space (inROI treats as
       %vectors by linear index, need to reshape to remove from here)
       Subset=inROI(roi2,(1/SF)*(Aprime(:)),(1/SF)*(Bprime(:)));
   
       %store step locations in the CS m and n
       CSdata(listCSs(j)).CSLocIDs=find(Subset);
       
       % Find the m and n indices in the CS m and n space
       [m,n_CS]=find(reshape(Subset,size(Aprime)));

       %Make an ID matrix in Track M and N space, use track numbers to find
       %the corerect spots
       DummyMatrix=zeros(size(TrackStruct(i).matrix(:,:,1)));
       n_index=CSdata(listCSs(j)).Tracks(n_CS);
       if size(n_index,1)<size(n_index,2)
           n_index=n_index';
       end
       CSind=sub2ind(size(DummyMatrix),m,n_index);
       CSdata(listCSs(j)).refLocIDs=CSind;
       DummyMatrix(CSind)=1;
       CSdata(listCSs(j)).IDmatrixMN=DummyMatrix;
       
       bw=createMask(roi2);
       bw=imclearborder(bw);
       bw=bwareafilt(bw,1);
       s=regionprops(bw,{'Centroid','Orientation','MajorAxisLength','MinorAxisLength'});
       CSdata(listCSs(j)).EllipseFit=s;

       close all;
       clear("fig1","roi2","roi1")
   end
   
   if MitoFlag==1
     save(fullfile(outputDir,strcat(filename(1:end-11),'_mito_','CSdata.mat')),'CSdata');
   elseif MitoFlag==-1
     save(fullfile(outputDir,strcat(filename(1:end-11),'_other_','CSdata.mat')),'CSdata');
   else
     save(fullfile(outputDir,filename),'CSdata');
   end
   
   
end



end


