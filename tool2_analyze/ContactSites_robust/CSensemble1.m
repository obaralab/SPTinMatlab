 
% CS Deff ensemble calculator

% Non-mito CS's are removed from control data

%Run in Condition parent directory
Final=dir(fullfile(pwd,'*_final.mat'));
load(char(Final.name),'Tracks');

%Run in the Condition Parent Folder - Find the CS data by cell
Files=dir(fullfile(pwd,'CSdata','*_CSdata.mat'));
files={Files.name}';

%allocate memory for full dataset stats
Din=NaN(size(Tracks,2),1);
Dout=NaN(size(Tracks,2),1);
Dother=NaN(size(Tracks,2),1);
RowNames2=cell(size(Tracks,2),1);
counter=0;

%Loop through each cell and compile Diffusion Data
for i=1:size(Tracks,2)
   
   %open each CSdata structure + record the file name
   filename=char(files(i)); 
   filebase=stripSuffix(filename,'_CSdata.mat');
   load(fullfile(pwd,'CSdata',filename),'CSdata');
   RowNames2{i}=char(filebase);
   
   %Allocate memory for cell specific data
%    RowLabels=cell(size(Tracks(i).MitoCSindex,2),1);
%    EllipseParam=NaN(size(Tracks(i).MitoCSindex,2),2);
    LinIDs=zeros(size(Tracks(i).matrix(:,:,1),1)*size(Tracks(i).matrix(:,:,1),2),size(Tracks(i).MitoCSindex,2));
%    Deff=zeros(size(Tracks(i).MitoCSindex,2),1);
   
   
   % Loop through only the mito-associated CSs
   for j=1:size(Tracks(i).MitoCSindex,2)
       counter=counter+1;
       RowLabels{counter}=strcat('Cell_',num2str(i),'_CS_',num2str(Tracks(i).MitoCSindex(j)));
       LinIDs(:,j)=CSdata(Tracks(i).MitoCSindex(j)).IDmatrixMN;
       Deff(counter)=mean(Tracks(i).Deff(CSdata(Tracks(i).MitoCSindex(j)).refLocIDs),'all','omitnan');
       EllipseParam(counter,:)=[CSdata(Tracks(i).MitoCSindex(j)).EllipseFit.MajorAxisLength CSdata(Tracks(i).MitoCSindex(j)).EllipseFit.MinorAxisLength];
   end 
   
   Din(i)=mean(Tracks(i).Deff(logical(sum(LinIDs,2))),'all','omitnan');
   NonMitoCS=setdiff(1:size(CSdata,2),Tracks(i).MitoCSindex);
   NMindex=[];
   for k=1:size(NonMitoCS,2)
      NMindex=[NMindex; setdiff(CSdata(NonMitoCS(k)).LocIDs,NMindex)];
   end
   Dother(i)=mean(Tracks(i).Deff(NMindex),'all','omitnan');
   Temp=zeros(size(LinIDs,1),1);
   Temp(NMindex)=1;
   Dout(i)=mean(Tracks(i).Deff(~logical(sum(LinIDs,2)+Temp)),'all','omitnan');
   Dcontrol((counter-j+1):counter)=Dout(i)*ones(j,1);  
   
end
Deff=Deff';
Dcontrol=Dcontrol';
T1=table(Deff,EllipseParam,Dcontrol);
T1.Properties.RowNames=RowLabels;
writetable(T1,'CSoutputFilt.xlsx','Sheet','DataByCS','WriteRowNames',true);

T2=table(Din,Dout,Dother);
T2.Properties.RowNames=RowNames2;
writetable(T2,'CSoutputFilt.xlsx','Sheet','DataByCell','WriteRowNames',true);

save('CSoutputFilt.mat','Din','Dout','T1','T2','Deff','Dcontrol','EllipseParam','Dother');
