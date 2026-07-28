
%CS refiner

% Version 2: Does all CSs, regardless of MitoFlag

%Load the final Track Structure and CSindexes
Final=dir(fullfile(pwd,'*_final.mat'));
load(char(Final.name));

%Run in the Condition Parent Folder - Find the CS data by cell
Files=dir(fullfile(pwd,'TrackData','*_CSdata.mat'));
files={Files.name}';

%Loop through each cell and refine center
for i=1:size(Files,1)
    
   filename=char(files(i)); 
   load(fullfile(pwd,'TrackData',filename),'CSdata');
      
   %Loop through each Mito CS and refine the center
   
   for j=1:size(CSdata,2)
       CSname=strcat(stripSuffix(filename,'CSdata.mat'), 'CS_',num2str(j),'_density.tif');
       imS=ChrisPrograms.loadtiff(fullfile(pwd,'CSsnaps',CSname));
       fig1=figure(1);
       imshow(imS);
       fig1.Position=[300 300 768 768];
       
       fig2=figure(2);
       filebase=stripSuffix(filename,'CSdata.mat');
       imM=ChrisPrograms.loadtiff(fullfile(pwd,'MaxInt',strcat(filebase,'3_MaxInt_RGB.tif')));
       imshow(imM);
       fig2.Position=[800 300 768 768];
       xlim((1/cs_config().DL_PixSize_um)*[CSdata(j).boundaries.x]); % per-camera struct-image px/um (was 6.25)
       ylim((1/cs_config().DL_PixSize_um)*[CSdata(j).boundaries.y]);
       
       figure(1);
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
   f=msgbox('Changing from center refinement to boundary refinment.','Changing Modes');
   
   %Establish variables for linear indexing
            A=Tracks(i).matrix(:,:,2);
            B=Tracks(i).matrix(:,:,3);
%             C=Tracks(i).Deff; 
   
   %Loop through each Mito CS and define the edge
   
   for j=1:size(CSdata,2)

       Bins=30*(-150:1:150);
       [NumLoc,~,~,~,~]=histcounts2(1000*(A-CSdata(j).refCenter(1)),1000*(B-CSdata(j).refCenter(2)),Bins,Bins);
       imG=imgaussfilt(NumLoc,[2 2]);
       imG=imG';
       cSF=255/(max(imG,[],'all','omitnan')-min(imG,[],'all','omitnan'));
       fig1=figure(1);
       imshow(cSF*(imG-min(imG,[],'all','omitnan')), jet, 'Border','tight');
       fig1.Position=[300 300 768 768];
       CSname=strcat(stripSuffix(filename,'CSdata.mat'), 'CS_',num2str(j),'_density2.tif');
       saveas(fig1,fullfile(pwd,'CSsnaps2',CSname));
       hold on
       scatter(151,151,'filled');
       
       roi2=drawfreehand;
       hold off
       %record the boundary in units of nm centered on CS
       CSdata(j).refboundary=[(30*roi2.Position(:,1))-4500 30*roi2.Position(:,2)-4500];
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
       %check if the center is in the ROI, if not flag the ROI as a repeat
       if ~inROI(roi2, 151,151)
           CSdata(j).RepeatFlag=true;
       end
       
       bw=createMask(roi2);
       bw=imclearborder(bw);
       bw=bwareafilt(bw,1);
       s=regionprops(bw,{'Centroid','Orientation','MajorAxisLength','MinorAxisLength'});
       CSdata(j).EllipseFit=s;
   end
   
   save(fullfile(pwd,'CSdata',char(files(i))),'CSdata');
   f=msgbox('Changing cells now.','Notice');
end

close(fig1);
