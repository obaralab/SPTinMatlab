
% Assemble Avg Contact Site

%Run in the Condition Parent Folder - Find the CS data by cell
Files=dir(fullfile(pwd,'CSdata','*_CSdata.mat'));
files={Files.name}';

%Establish a counting variable to expand structures
counter1=0;
%RowNames={};
counter2=0;
%RowNames2={};

%Loop through each cell and compile Diffusion Data
for i=1:size(files,1)
    
   %open each CSdata structure + record the file name
   filename=char(files(i)); 
   filebase=filename(1:end-11);
   load(fullfile(pwd,'CSdata',filename),'CSdata');
       
    for j=1:size(CSdata,2)
        if isfield(CSdata,'EllipseFit')
                if  ~isfield(CSdata,'RepeatFlag')
                    CSdata(j).RepeatFlag=[];
                end
                if (isfield(CSdata,'RepeatFlag') && isempty(CSdata(j).RepeatFlag))           
                      if CSdata(j).MitoFlag==1  
                            counter1=counter1+1;
                            CSmito(counter1)=CSdata(j);        
                      else
                            counter2=counter2+1;
                            CSother(counter2)=CSdata(j);
                      end
                end
        end
    end
    
end

disp(strcat('Total of n=',num2str(counter2),' CS outside Mitochondria.'));
disp(strcat('Remaining n=',num2str(counter1),' CS were assembled.'));

save('CSfits.mat','CSmito','CSother');