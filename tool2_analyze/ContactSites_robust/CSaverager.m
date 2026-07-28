
% Assemble Avg Contact Site

%Run in Condition parent directory
Final=dir(fullfile(pwd,'*_final.mat'));
load(char(Final.name),'Tracks');

%Run in the Condition Parent Folder - Find the CS data by cell
Files=dir(fullfile(pwd,'CSdata','*_CSdata.mat'));
files={Files.name}';

%Allocate space for labels
RowNames2=cell(size(Tracks,2),1);
counter1=0;
counter2=0;

%Allocate space for outputs
CSstd=struct('Cell',[],'cellIndex',[],'csID',[],'center',[],'numLoc',[],'MajorA',[],'MinorA',[], 'meanDeff',[], 't',[],'x',[],'y',[],'D',[],'X_c',[],'Y_c',[]);
CSprofile=struct('Cell',[],'cellIndex',[],'csID',[],'center',[],'numLoc',[],'MajorA',[],'MinorA',[], 'meanDeff',[], 't',[],'x',[],'y',[],'D',[],'X_c',[],'Y_c',[]);
%Loop through each cell and compile Diffusion Data
for i=1:size(Tracks,2)
    
   %open each CSdata structure + record the file name
   filename=char(files(i)); 
   filebase=stripSuffix(filename,'_CSdata.mat');
   load(fullfile(pwd,'CSdata',filename),'CSdata');
   RowNames2{i}=char(filebase);
   
   %Define Linear Indexing variables in MN space
   A=Tracks(i).matrix(:,:,2);
   B=Tracks(i).matrix(:,:,3);
   C=Tracks(i).Deff; 
   T=Tracks(i).matrix(:,:,1);
    
    for j=1:size(CSdata,2)
      if CSdata(j).MitoFlag==1  
        if CSdata(j).EllipseFit.MajorAxisLength/CSdata(j).EllipseFit.MinorAxisLength>2.5
            counter2=counter2+1;
            CSprofile(counter2).Cell=filebase;
            CSprofile(counter2).cellIndex=i;
            CSprofile(counter2).csID=j;
            CSprofile(counter2).center=CSdata(j).refCenter;
            CSprofile(counter2).numLoc=size(CSdata(j).refLocIDs,1);
            CSprofile(counter2).MajorA=CSdata(j).EllipseFit.MajorAxisLength;
            CSprofile(counter2).MinorA=CSdata(j).EllipseFit.MinorAxisLength;
            CSprofile(counter2).meanDeff=mean(Tracks(i).Deff(CSdata(j).refLocIDs),'all','omitnan');
            CSprofile(counter2).t=T(CSdata(j).refLocIDs);
            CSprofile(counter2).x=A(CSdata(j).refLocIDs);
            CSprofile(counter2).y=B(CSdata(j).refLocIDs);
            CSprofile(counter2).D=C(CSdata(j).refLocIDs);
            CSprofile(counter2).X_c=A(CSdata(j).refLocIDs)-CSdata(j).refCenter(1);
            CSprofile(counter2).Y_c=B(CSdata(j).refLocIDs)-CSdata(j).refCenter(2);
        elseif CSdata(j).EllipseFit.MajorAxisLength/CSdata(j).EllipseFit.MinorAxisLength<=2.5
            counter1=counter1+1;
            CSstd(counter1).Cell=filebase;
            CSstd(counter1).cellIndex=i;
            CSstd(counter1).csID=j;
            CSstd(counter1).center=CSdata(j).refCenter;
            CSstd(counter1).numLoc=size(CSdata(j).refLocIDs,1);
            CSstd(counter1).MajorA=CSdata(j).EllipseFit.MajorAxisLength;
            CSstd(counter1).MinorA=CSdata(j).EllipseFit.MinorAxisLength;
            CSstd(counter1).meanDeff=mean(Tracks(i).Deff(CSdata(j).refLocIDs),'all','omitnan');
            CSstd(counter1).t=T(CSdata(j).refLocIDs);
            CSstd(counter1).x=A(CSdata(j).refLocIDs);
            CSstd(counter1).y=B(CSdata(j).refLocIDs);
            CSstd(counter1).D=C(CSdata(j).refLocIDs);
            CSstd(counter1).X_c=A(CSdata(j).refLocIDs)-CSdata(j).refCenter(1);
            CSstd(counter1).Y_c=B(CSdata(j).refLocIDs)-CSdata(j).refCenter(2);
        else
            error('CS has a mito flag but no Ellipse fit.');
        end
      end   
    end
    
end

disp(strcat('Total of n=',num2str(counter2),' CS with profile view.'));
disp(strcat('Remaining n=',num2str(counter1),' CS were assembled.'));

save('AssembledCSforAvg.mat','CSstd','CSprofile');