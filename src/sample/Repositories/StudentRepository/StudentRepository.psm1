using module Student

class StudentRepository {
	$file
	
	StudentRepository ([string] $Path) {
		$this.File = Get-Item $Path
	}
	
	[Student[]] getStudents () {
		$RawStudents = ConvertFrom-Json -AsHashtable -InputObject (Get-Content -Raw $this.File)
		
		[student[]] $StudentObjects = @()
		foreach ($RawStudent in $RawStudents) {
			$StudentObjects += [Student]::new($RawStudent.FirstName, $RawStudent.LastName, $RawStudent.FullName)
		}
		
		return $StudentObjects
	}
	
	[void] removeStudent([student] $Student) {
		$Students = $this.getStudents()
		
		$Students = $Students.Where{$_.FullName -ne $Student.FullName}
		
		$this.saveStudents($Students)
	}
	
	
	[void] addStudent([student] $Student) {
		$Students = $this.getStudents()
		
		$Students += $student
		
		$this.saveStudents($Students)
	}
	
	[void] saveStudents ([student[]] $Students) {
		$json = ConvertTo-Json -InputObject $Students -depth 10
		
		Set-Content -Path $this.File -value $json
	}
	
	[Student] getStudent ([string]$FullName) {
		return ($this.GetStudents().Where{$_.FullName -eq $FullName})[0]
		#return $thisstudent[0]
	}
	
}