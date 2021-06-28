class Student {
	[string] $FirstName
	[string] $LastName
	[string] $FullName
	
	Student ($FirstName, $LastName, $FullName) {
		$this.FirstName = $FirstName
		$this.LastName = $LastName
		$this.FullName = $Fullname
	}
	
	[string] getFirstName() { return $this.FirstName }
	[string] getLastName() { return $this.LastName }
	[string] getFullName() { return $this.FullName }
}