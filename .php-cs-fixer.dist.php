<?php

$finder = PhpCsFixer\Finder::create()
    ->in(__DIR__)
    ->ignoreDotFiles(false);

$config = new PhpCsFixer\Config();

return $config
    ->setRules([
        '@Symfony' => true,
        'array_indentation' => true,
    ])
    ->setFinder($finder)
    ->setCacheFile(__DIR__.'/var/cache/.php-cs-fixer.cache');
