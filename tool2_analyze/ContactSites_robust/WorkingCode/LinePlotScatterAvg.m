
function [Var1,Var2,X,Y]=LinePlotScatterAvg(Xin,Yin,VarIn,LineEndpts)

%Input notes:

% LineEndpts is of form [x1 x2; y1 y2];

x(1)=LineEndpts(1,1);
x(2)=LineEndpts(1,2);
y(1)=LineEndpts(2,1);
y(2)=LineEndpts(2,2);
A=Xin;
B=Yin;
C=VarIn;
%Output notes:
% Var,X,Y are the x and y points and associated variable along the line as
% columnn vectors

%Define the Kernel to trace with here in nm (e.g. [50 50] means +/- 50 nm
%in both x and y dimensions).
Kernel=[20 20];

%Define stepping rule for parametric variable here. 
    %If constant step size desired, use this line with number in nm:
        StepSize=10;
        ConstrainSteps=true;
    %If constant number of steps is desired, use this line with number
    %here: (NOTE DID NOT FINISH THIS CODE NEED TO ADD IT AT LINE 96
%       NumSteps=50;
%       ConstrainSteps=false;

%Define the variable output as Var at line 84. Any variable defined as a
%function of m and n can be used.

xlim([-1 1]);
ylim([-1 1]);

if ConstrainSteps==true
    % Define x and y spacing
        xStep=(abs(x(2)-x(1)))/100;
        yStep=(abs(y(2)-y(1)))/100;
        
    % Generate the x and y axes along the parametric variable (as vector index)    
        if (x(2)-x(1))>0
            X=x(1):xStep:x(2);
        elseif (x(1)-x(2))>0
            X=x(2):xStep:x(1);
        else
            X=zeros(101,1);
        end
        if (y(2)-y(1))>0
            Y=y(1):yStep:y(2);
        elseif (y(1)-y(2))>0
            Y=y(2):yStep:y(1);
        else
            Y=zeros(101,1);
        end
    
    % Align the two axes so vector index is shared
        if ((x(2)-x(1))*(y(2)-y(1)))<=0
            Y=flipud(Y);
        end
    
        Var1=NaN(size(X));
        Var2=NaN(size(X));
    for k=1:size(X,2)
       
       %Establish conditional logical matrices
       c1=A<=(X(k)+Kernel(1)/1000);
       c2=A>=(X(k)-Kernel(1)/1000);
       c3=B<=(Y(k)+Kernel(2)/1000);
       c4=B>=(Y(k)-Kernel(2)/1000);
        
       Var1(k)=mean(C(find(c1.*c2.*c3.*c4)),'all','omitnan');
       Var2(k)=sum(c1.*c2.*c3.*c4,'all','omitnan');
    end
       
    % Now define for constant number of steps
    
end

end