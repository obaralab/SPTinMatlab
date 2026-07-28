
%CS refiner

%use the Wacom Pad if you can, the results will be significantly improved
%Consider adding Feret's angle and diameter to the code at line 83
%(bwferet)


%Load the final Track Structure and CSindexes
Final=dir(fullfile(pwd,'*_final.mat'));
load(char(Final.name));
load('CSindexing.mat');

%Run in the Condition Parent Folder - Find the CS data by cell
Files=dir(fullfile(pwd,'TrackData','*_CSdata.mat'));
files={Files.name}';

%Loop through each cell and refine center
for i=1:size(Files,1)
    
   filename=char(files(i)); 
   load(fullfile(pwd,'TrackData',filename),'CSdata');
      
   %Loop through each Mito CS and refine the center
   
   for j=1:size(CSinfo(i).CSindex,2)
       CSname=strcat(filename(1:end-10), 'CS_',num2str(CSinfo(i).CSindex(j)),'_density.tif');
       imS=ChrisPrograms.loadtiff(fullfile(pwd,'CSsnaps',CSname));
       fig1=figure(1);
       imshow(imS);
       fig1.Position=[300 300 768 768];
       
       roi1=drawpoint;
       ImageSize=[CSdata(CSinfo(i).CSindex(j)).boundaries.x(2)-CSdata(CSinfo(i).CSindex(j)).boundaries.x(1) CSdata(CSinfo(i).CSindex(j)).boundaries.y(2)-CSdata(CSinfo(i).CSindex(j)).boundaries.y(1)];
        if ImageSize(1)>=ImageSize(2)
            SF=(CSdata(CSinfo(i).CSindex(j)).boundaries.x(2)-CSdata(CSinfo(i).CSindex(j)).boundaries.x(1))/1200;
        elseif ImageSize(1)<ImageSize(2)
            SF=(CSdata(CSinfo(i).CSindex(j)).boundaries.y(2)-CSdata(CSinfo(i).CSindex(j)).boundaries.y(1))/1200;
        end
       CSdata(CSinfo(i).CSindex(j)).refCenter=[(SF*roi1.Position(1))+CSdata(CSinfo(i).CSindex(j)).boundaries.x(1) (SF*roi1.Position(2))+CSdata(CSinfo(i).CSindex(j)).boundaries.y(1)];
   end
   
   %Notify the user that we are changing to edge defining
   f=msgbox('Changing from center refinement to boundary refinment.','Changing Modes');
   
   %Establish variables for linear indexing
            A=Tracks(i).matrix(:,:,2);
            B=Tracks(i).matrix(:,:,3);
            C=Tracks(i).Deff; 
   
   %Loop through each Mito CS and define the edge
   
   for j=1:size(CSinfo(i).CSindex,2)

       Bins=30*(-30:1:30);
       [NumLoc,~,~,~,~]=histcounts2(1000*(A-CSdata(CSinfo(i).CSindex(j)).refCenter(1)),1000*(B-CSdata(CSinfo(i).CSindex(j)).refCenter(2)),Bins,Bins);
       imG=imgaussfilt(NumLoc,[2 2]);
       imG=imG';
       cSF=255/(max(imG,[],'all','omitnan')-min(imG,[],'all','omitnan'));
       fig1=figure(1);
       imshow(cSF*(imG-min(imG,[],'all','omitnan')), jet, 'Border','tight');
       fig1.Position=[300 300 768 768];
       hold on
       scatter(31,31,'filled');
       
       roi2=drawfreehand;
       hold off
       %record the boundary in units of nm centered on CS
       CSdata(CSinfo(i).CSindex(j)).refboundary=[(30*roi2.Position(:,1))-900 30*roi2.Position(:,2)-900];
       %remove NaN's so inROI command can work
       Aprime=A;
       Aprime(~isfinite(Aprime))=0;
       Bprime=B;
       Bprime(~isfinite(Bprime))=0;
       %generate an identity matrix in m and n space
       Subset=inROI(roi2,(1000/30)*(Aprime-CSdata(CSinfo(i).CSindex(j)).refCenter(1))+30,(1000/30)*(Bprime-CSdata(CSinfo(i).CSindex(j)).refCenter(2))+30);
       %store step identities and locations (ID matrix is also saved for
       %ease of combining CSs)
       CSdata(CSinfo(i).CSindex(j)).IDmatrixMN=Subset;
       CSdata(CSinfo(i).CSindex(j)).refLocIDs=find(Subset);
       
       bw=createMask(roi2);
       bw=imclearborder(bw);
       bw=bwareafilt(bw,1);
       s=regionprops(bw,{'Centroid','Orientation','MajorAxisLength','MinorAxisLength'});
       CSdata(CSinfo(i).CSindex(j)).EllipseFit=s;
   end
   
   save(fullfile(pwd,'CSData',char(files(i))),'CSdata');
   f=msgbox('Changing cells now.','Notice');
end

close(fig1);
