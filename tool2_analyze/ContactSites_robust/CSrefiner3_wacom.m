
%CS refiner

% Version 2: Does all CSs, regardless of MitoFlag

%Load the final Track Structure and CSindexes
% Final=dir(fullfile(pwd,'*_final.mat'));
% load(char(Final.name));

% Just load the Tracks structure you want, Jesus

%Run in the Condition Parent Folder - Find the CS data by cell
Files=dir(fullfile(pwd,'TrackData','*_CSdata.mat'));
files={Files.name}';

%Loop through each cell and refine center
for i=1:size(Files,1)
    
   filename=char(files(i)); 
   load(fullfile(pwd,'TrackData',filename),'CSdata');
   %Figure out who has been skipped bc of a flag
   MitoFlag=NaN(size(CSdata));
   for k=1:size(CSdata,2)
       MitoFlag(k)=CSdata(k).MitoFlag;
   end
   listCSs=find(~MitoFlag);
      
   %Loop through each Non-Mito CS and refine the center
   
   for j=1:size(listCSs,2)
       % Generate references in case you need to check anything

        X=Tracks(i).matrix(:,CSdata(listCSs(j)).Tracks,2)-CSdata(listCSs(j)).center(1);
        Y=Tracks(i).matrix(:,CSdata(listCSs(j)).Tracks,3)-CSdata(listCSs(j)).center(2);
        %Prob don't need this unless you start t-filtering, but if so change it here:
        T=Tracks(i).matrix(:,CSdata(listCSs(j)).Tracks,2);

           % XY plot
            figure;
            plot(X,Y);
            xlim([-1.5 1.5]);
            ylim([-1.5 1.5]);
            axis square

           % RT plot
            figure;
            plot(cs_config().FrameInt_s*T,sqrt(X.^2+Y.^2),'LineWidth',1.5); % per-run dt (was 0.011)
            ylim([-0.5 3.5]);
            %xlim([0 2500]);
            hold on
            yline(0,'--');
            set(gcf,'Position',[50 250 200 400]);
            xlabel('Time (sec)');
            ylabel('Distance from CS Center (\mum)');
            set(gca,'FontSize',20);

       % Make a cute little CS to look at
            ROI=[-20 20]; % +/- Dimensions analyzed in pixels (+/- 20 is 40 pix=1.2 um)
            % Change the last input if you want bigger regions (currently set to
            % 1.2 um neighborhoods for visualization (1.024 for analysis))
            imG=LocDensityFigGenerate(X,Y,30,ROI);
            figure;
            cSF=255/(max(imG,[],'all','omitnan')-min(imG,[],'all','omitnan'));
            imshow(cSF*(imG-min(imG,[],'all','omitnan')), jet, 'Border','tight');
            set(gcf,'Position',[100 200 200 200]);
       
       roi1=drawpoint;
       ImageSize=[CSdata(j).boundaries.x(2)-CSdata(j).boundaries.x(1) CSdata(j).boundaries.y(2)-CSdata(j).boundaries.y(1)];
        if ImageSize(1)>=ImageSize(2)
            SF=(CSdata(j).boundaries.x(2)-CSdata(j).boundaries.x(1))/1200;
        elseif ImageSize(1)<ImageSize(2)
            SF=(CSdata(j).boundaries.y(2)-CSdata(j).boundaries.y(1))/1200;
        end
       CSdata(j).refCenter=[(SF*roi1.Position(1))+CSdata(j).boundaries.x(1) (SF*roi1.Position(2))+CSdata(j).boundaries.y(1)];
   end
   
   %Notify the user that we are changing to edge defining
   msgbox('Changing from center refinement to boundary refinment.','Changing Modes');
   
   %Establish variables for linear indexing
            A=Tracks(i).matrix(:,:,2);
            B=Tracks(i).matrix(:,:,3);
           % C=Tracks(i).Deff; 
   
   %Loop through each Mito CS and define the edge
   
   for j=1:size(CSdata,2)

       Bins=30*(-30:1:30);
       [NumLoc,~,~,~,~]=histcounts2(1000*(A-CSdata(j).refCenter(1)),1000*(B-CSdata(j).refCenter(2)),Bins,Bins);
       imG=imgaussfilt(NumLoc,[2 2]);
       imG=imG';
       cSF=255/(max(imG,[],'all','omitnan')-min(imG,[],'all','omitnan'));
       fig1=figure(1);
       imshow(cSF*(imG-min(imG,[],'all','omitnan')), jet, 'Border','tight');
%        fig1.Position=[300 300 768 768];
        set(gcf,'Position',[500 250 500 500]);
       CSname=strcat(stripSuffix(filename,'CSdata.mat'), 'CS_',num2str(j),'_density2.tif');
       saveas(fig1,fullfile(pwd,'CSsnaps2',CSname));
       hold on
       scatter(31,31,'filled');
       
       roi2=drawfreehand;
       hold off
       %record the boundary in units of nm centered on CS
       CSdata(j).refboundary=[(30*roi2.Position(:,1))-900 30*roi2.Position(:,2)-900];
       %remove NaN's so inROI command can work
       Aprime=A;
       Aprime(~isfinite(Aprime))=0;
       Bprime=B;
       Bprime(~isfinite(Bprime))=0;
       %generate an identity matrix in m and n space
       Subset=inROI(roi2,(1000/30)*(Aprime-CSdata(j).refCenter(1))+30,(1000/30)*(Bprime-CSdata(j).refCenter(2))+30);
       %store step identities and locations (ID matrix is also saved for
       %ease of combining CSs)
       CSdata(j).IDmatrixMN=Subset;
       CSdata(j).refLocIDs=find(Subset);
       
       bw=createMask(roi2);
       bw=imclearborder(bw);
       bw=bwareafilt(bw,1);
       s=regionprops(bw,{'Centroid','Orientation','MajorAxisLength','MinorAxisLength'});
       CSdata(j).EllipseFit=s;
   end
   
   save(fullfile(pwd,'CSdata',char(files(i))),'CSdata');
   msgbox('Changing cells now.','Notice');
end

close(fig1);
