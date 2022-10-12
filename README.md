# SRU AlmaMarc Import

A set of plugins to carry out a search in an SRU-enabled Alma catalog and to import catalog records.

Developed at University of Zurich (UZH) for integration with swisscovery, a national platform that brings together scientific information from around 490 libraries in Switzerland.

The software here is provided as is, with sufficient documentation for integration with other EPrints repositories. However, each repository (and the SRU interface of your institutions' Alma catalog) has its individual data structure, which requires modification of the provided configuration files on your own. A lot of the filter / transformation rules implemented there are specific for both the ZORA repository by UZH and the Alma catalog by swisscovery. The latter covers a cross-section of records cataloged according to different cataloging rules (RDA, KIDS, IDS, ... ) across time and library consortium (NEBIS, IDS, Rero, ...). The filter and transformation rules try to cope with this at best effort, but may not be appropriate in your environment. Therefore, please note that we are not able to provide any support.

## Preparation

It is recommended to inspect first the response of the "Explain" operation of your SRU instance. It allows to retrieve the metadata schema (field mapping for an SRU query) and fields for which sorting is allowed.

Example: [swisscovery SRU Explain](https://swisscovery.slsp.ch/view/sru/41SLSP_NETWORK?version=1.2&operation=explain)  

With this information, you then can configure the query field mappings and order options in cfg.d/z_sru.pl. The SRU plugin provides a simplified query language for end users (see Searching below).

More information on Alma's SRU is available at [ExLibris]( https://developers.exlibrisgroup.com/alma/integrations/sru/)


## Installation

- copy the available plug-ins, configuration and phrases to their corresponding places
- install the necessary CPAN modules (see requirements below)
- edit the cfg.d/z_sru.pl and cfg.d/z_marc_import.pl files (see configuration)
- edit the phrase file(s) so that it matches your repository / SRU library catalog 
- restart your web server
- In Manage Deposits, the plugin should appear in your list


## General setup of plugins

- Screen/Import/SRU.pm - The search GUI to SRU. Controlled by cfg.d/z_sru.pl configuration
 
- Import/SRU.pm - Interface plugin, fetches SRU response and identifies MarcXML records.

- Import/AlmaMarc.pm - the workhorse that converts a single MarcXML record to epdata. It should be quite generic, however, please inspect code marked as "ZORA specific" and adapt it. AlmaMarc.pm is controlled by the cfg.d/z_marc_import.pl configuration. The convert_input() method of AlmaMarc.pm does a general parse of each MARC field/subfield and identifies a conversion method for each. The value of the parsed MARC field/subfield is passed as variable $marcvalue to the conversion method.

## Configuration

cfg.d/z_sru.pl 

contains base URLs of the SRU and catalog instances, query field mapping, order options and further.


cfg.d/z_marc_import.pl

contains hashes or arrays of hashes that define the mappings for conversions and filters. Important hashes are:

`$c->{marc_import_mappings}`
maps MARC fields / subfields to a method in AlmaMarc.pm that converts the data into a given EPrints field.

General structure (based on an example)

```
'marcfieldtype' => 'datafield',   # value can be controlfield or datafield
'marcfield' => '260', # MARC field number
'marcsubfield' => 'a', # MARC subfield name
'fieldname' => 'place_of_pub', # EPrints field name, if empty '', the method has to define the EPrints field itself
'method' => 'marc2place',  # name of conversion method in AlmaMarc.pm
'filter' => 'garbage', # name of a filter hash to be used in method (see example below)
```

Every conversion method takes the following arguments: 
```
$epdata, # the eprint data hash
$fieldname, # the EPrints field name  
$marcvalue, # the parsed value
$opt # additional options (ind options identified with MARC field)
```


Sometimes a MARC field may have several subfields with related or interdependent information. AlmaMarc.pm provides an utility method get_marc_subfield that can extract another subfield for the current parsed MARC field (which is stored in the plugin's parameter {currentnode} ).

E.g. MARC field 024 is used for identifiers of any kind (DOI, PMID, ...). The value of the identifier is 024_a, the kind is defined in 024_2. Only one hash is needed to define the conversion method.

```
{
  'marcfieldtype' => 'datafield',
  'marcfield' => '024',
  'marcsubfield' => 'a',
  'fieldname' => '',
  'method' => 'marc2doi_pmid',
},
``` 

When field 024_a is identified, marc2doi_pmid is called. marc2doi_pmid itself calls get_marc_subfield( '2' ) to get the value of subfield 2 of the current node (i.e. MARC field 024).


Filter hashes:
`$c->{marcfilter}->{some_filter_name}` contains an array of regular expressions, usually to remove superfluous content from a MARC value. Make sure to encode UTF-8 characters as \x{UTF-8 hex code} . 


## Searching

A search query can be entered without field names. Example:

Atkins Peter Physical Chemistry 2022

A query can also be entered with Boolean operators (AND, OR) and field names. Examples:

AU="Atkins Peter" AND TI="Physical Chemistry" AND PY=2022
AU="Atkins Peter" AND TI="Physical Chemistry" AND PY<>2022  

Possible field names:

AU= Author
TI= Title
PY= Publication Year
NA= Names
CN= Contributor
ID= Alma id or Permalink
DOI= DOI
ISBN= ISBN
ISSN= ISSN
ORCID= ORCID	
PB= Publisher
PL= Publisher Location
CO= Country
SE= Series	
DDC = Dewey Decimal Class Number
LA= Language
VL= Volume
PG= Pages

The list of available fields depends on an institution's SRU implementation.


## Requirements

CPAN modules (recent versions)
- Date::Calc
- Text::Roman
- Text::Unidecode
